// Kubernetes management for premium "custom bots".
// Each custom bot gets its own pod in CUSTOM_BOTS_NAMESPACE: a Deployment
// running a per-language runner image that clones the user's public GitHub
// repo and executes their startup script, a ClusterIP Service, and — when a
// domain is configured — a cert-manager Certificate + Traefik Ingress for
// automatic TLS.
const k8s = require('@kubernetes/client-node');

const NAMESPACE = process.env.CUSTOM_BOTS_NAMESPACE || 'custom-bots';
const IMAGE_PREFIX = process.env.RUNNER_IMAGE_PREFIX || 'ghcr.io/chillboio-studios/cpb-runner';
const BASE_DOMAIN = (process.env.CUSTOM_BOT_BASE_DOMAIN || 'custom.creatorplaza.nl').toLowerCase();
const DNS_ISSUER = process.env.CUSTOM_BOT_DNS_ISSUER || 'letsencrypt-dns';
const HTTP_ISSUER = process.env.CUSTOM_BOT_HTTP_ISSUER || 'letsencrypt-http';
// Hostnames under this suffix live in the cluster's Cloudflare zone, so the
// DNS-01 issuer can solve them; anything else falls back to HTTP-01 via
// Traefik (requires the domain's DNS to point at the cluster ingress).
const DNS_SUFFIX = (process.env.CUSTOM_BOT_DNS_SUFFIX || 'creatorplaza.nl').toLowerCase();

let core = null;
let apps = null;
let networking = null;
let custom = null;

try {
  if (process.env.KUBERNETES_SERVICE_HOST) {
    const kc = new k8s.KubeConfig();
    kc.loadFromCluster();
    core = kc.makeApiClient(k8s.CoreV1Api);
    apps = kc.makeApiClient(k8s.AppsV1Api);
    networking = kc.makeApiClient(k8s.NetworkingV1Api);
    custom = kc.makeApiClient(k8s.CustomObjectsApi);
  }
} catch (e) {
  console.log('[k8s] in-cluster config unavailable — custom bots disabled:', e.message);
}

function available() {
  return !!apps;
}

function baseName(id) {
  return `cb-${id}`;
}

function envSecretName(id) {
  return `cb-${id}-env`;
}

function tlsSecretName(id) {
  return `cb-${id}-tls`;
}

function issuerFor(hostname) {
  return String(hostname).toLowerCase().endsWith(`.${DNS_SUFFIX}`) ? DNS_ISSUER : HTTP_ISSUER;
}

function isNotFound(e) {
  return e?.statusCode === 404 || e?.code === 404 || e?.body?.code === 404 ||
    /not found/i.test(e?.message || '');
}

function isConflict(e) {
  return e?.statusCode === 409 || e?.code === 409 || e?.body?.code === 409;
}

async function ignoreNotFound(promise) {
  try {
    return await promise;
  } catch (e) {
    if (!isNotFound(e)) throw e;
    return null;
  }
}

// Create-or-recreate: the API is the single writer for these resources, so
// delete+create on conflict is simpler and safer than tracking resourceVersions.
async function upsert(createFn, removeFn) {
  try {
    return await createFn();
  } catch (e) {
    if (!isConflict(e)) throw e;
    await ignoreNotFound(removeFn());
    return createFn();
  }
}

function labels(name) {
  return { app: name, 'creatorplaza-bot': 'true' };
}

function deploymentBody(bot, hasEnv) {
  const name = baseName(bot.id);
  const port = bot.port;
  const container = {
    name: 'bot',
    image: `${IMAGE_PREFIX}-${bot.language}:latest`,
    imagePullPolicy: 'Always',
    ports: [{ containerPort: port }],
    env: [
      { name: 'REPO_URL', value: bot.repo_url },
      { name: 'BRANCH', value: bot.branch || 'main' },
      { name: 'LANGUAGE', value: bot.language },
      { name: 'STARTUP_SCRIPT', value: bot.startup_script },
    ],
    ...(hasEnv ? { envFrom: [{ secretRef: { name: envSecretName(bot.id) } }] } : {}),
    readinessProbe: {
      tcpSocket: { port }, initialDelaySeconds: 10,
      periodSeconds: 15, failureThreshold: 6,
    },
    livenessProbe: {
      tcpSocket: { port }, initialDelaySeconds: 30,
      periodSeconds: 30, failureThreshold: 6,
    },
    resources: {
      requests: { cpu: '100m', memory: '256Mi' },
      limits: { cpu: '1000m', memory: '1Gi' },
    },
    securityContext: {
      allowPrivilegeEscalation: false,
      capabilities: { drop: ['ALL'] },
      runAsNonRoot: true,
      runAsUser: 1000,
      runAsGroup: 1000,
    },
  };
  return {
    apiVersion: 'apps/v1',
    kind: 'Deployment',
    metadata: { name, namespace: NAMESPACE, labels: labels(name) },
    spec: {
      replicas: 1,
      selector: { matchLabels: { app: name } },
      template: {
        metadata: { labels: labels(name) },
        spec: {
          automountServiceAccountToken: false,
          imagePullSecrets: [{ name: 'ghcr-pull-secret' }],
          containers: [container],
        },
      },
    },
  };
}

function serviceBody(bot) {
  const name = baseName(bot.id);
  return {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: { name, namespace: NAMESPACE, labels: labels(name) },
    spec: {
      selector: { app: name },
      ports: [{ name: 'http', port: bot.port, targetPort: bot.port }],
    },
  };
}

function certificateBody(bot) {
  const name = baseName(bot.id);
  return {
    apiVersion: 'cert-manager.io/v1',
    kind: 'Certificate',
    metadata: { name, namespace: NAMESPACE },
    spec: {
      secretName: tlsSecretName(bot.id),
      issuerRef: { name: issuerFor(bot.hostname), kind: 'ClusterIssuer' },
      dnsNames: [bot.hostname],
    },
  };
}

function ingressBody(bot) {
  const name = baseName(bot.id);
  return {
    apiVersion: 'networking.k8s.io/v1',
    kind: 'Ingress',
    metadata: {
      name,
      namespace: NAMESPACE,
      labels: labels(name),
      annotations: {
        'traefik.ingress.kubernetes.io/router.entrypoints': 'websecure',
        'traefik.ingress.kubernetes.io/router.tls': 'true',
      },
    },
    spec: {
      ingressClassName: 'traefik',
      tls: [{ secretName: tlsSecretName(bot.id), hosts: [bot.hostname] }],
      rules: [{
        host: bot.hostname,
        http: {
          paths: [{
            path: '/',
            pathType: 'Prefix',
            backend: { service: { name, port: { number: bot.port } } },
          }],
        },
      }],
    },
  };
}

function secretBody(bot, env) {
  return {
    apiVersion: 'v1',
    kind: 'Secret',
    metadata: { name: envSecretName(bot.id), namespace: NAMESPACE },
    type: 'Opaque',
    stringData: env,
  };
}

// Create or update all resources for a custom bot.
// `env` semantics:
//   undefined -> leave the existing env Secret untouched (update without env)
//   {..}      -> upsert the env Secret with these values
//   {}        -> delete the env Secret (explicitly cleared)
// The Deployment references the Secret whenever the stored doc has env_keys.
async function applyCustomBot(bot, env) {
  const name = baseName(bot.id);
  const envKeys = bot.env_keys || [];

  if (env !== undefined) {
    const keys = Object.keys(env || {});
    if (keys.length) {
      await upsert(
        () => core.createNamespacedSecret({ namespace: NAMESPACE, body: secretBody(bot, env) }),
        () => core.deleteNamespacedSecret({ name: envSecretName(bot.id), namespace: NAMESPACE })
      );
    } else {
      await ignoreNotFound(core.deleteNamespacedSecret({
        name: envSecretName(bot.id), namespace: NAMESPACE,
      }));
    }
  }

  await upsert(
    () => apps.createNamespacedDeployment({ namespace: NAMESPACE, body: deploymentBody(bot, envKeys.length > 0) }),
    () => apps.deleteNamespacedDeployment({ name, namespace: NAMESPACE })
  );

  await upsert(
    () => core.createNamespacedService({ namespace: NAMESPACE, body: serviceBody(bot) }),
    () => core.deleteNamespacedService({ name, namespace: NAMESPACE })
  );

  if (bot.hostname) {
    await upsert(
      () => custom.createNamespacedCustomObject({
        group: 'cert-manager.io', version: 'v1', namespace: NAMESPACE,
        plural: 'certificates', body: certificateBody(bot),
      }),
      () => custom.deleteNamespacedCustomObject({
        group: 'cert-manager.io', version: 'v1', namespace: NAMESPACE,
        plural: 'certificates', name,
      })
    );
    await upsert(
      () => networking.createNamespacedIngress({ namespace: NAMESPACE, body: ingressBody(bot) }),
      () => networking.deleteNamespacedIngress({ name, namespace: NAMESPACE })
    );
  } else {
    await ignoreNotFound(custom.deleteNamespacedCustomObject({
      group: 'cert-manager.io', version: 'v1', namespace: NAMESPACE,
      plural: 'certificates', name,
    }));
    await ignoreNotFound(networking.deleteNamespacedIngress({ name, namespace: NAMESPACE }));
  }
}

async function removeCustomBot(id) {
  const name = baseName(id);
  await ignoreNotFound(networking.deleteNamespacedIngress({ name, namespace: NAMESPACE }));
  await ignoreNotFound(custom.deleteNamespacedCustomObject({
    group: 'cert-manager.io', version: 'v1', namespace: NAMESPACE,
    plural: 'certificates', name,
  }));
  await ignoreNotFound(apps.deleteNamespacedDeployment({ name, namespace: NAMESPACE }));
  await ignoreNotFound(core.deleteNamespacedService({ name, namespace: NAMESPACE }));
  await ignoreNotFound(core.deleteNamespacedSecret({ name: envSecretName(id), namespace: NAMESPACE }));
  await ignoreNotFound(core.deleteNamespacedSecret({ name: tlsSecretName(id), namespace: NAMESPACE }));
}

// Delete the bot's pods; the Deployment controller recreates them, which
// re-runs the clone + startup script (fresh deploy of latest repo HEAD).
async function restartCustomBot(id) {
  const name = baseName(id);
  const pods = await core.listNamespacedPod({
    namespace: NAMESPACE, labelSelector: `app=${name}`,
  });
  const items = pods?.items || [];
  for (const p of items) {
    await ignoreNotFound(core.deleteNamespacedPod({
      name: p.metadata.name, namespace: NAMESPACE,
    }));
  }
  return items.length;
}

function summarizeDeployment(dep) {
  const st = dep?.status || {};
  const ready = st.readyReplicas || 0;
  const desired = dep?.spec?.replicas ?? 1;
  if (ready >= desired && desired > 0) return { status: 'online', readyReplicas: ready, replicas: st.replicas || 0 };
  const progressing = (st.conditions || []).find(c => c.type === 'Progressing');
  const available = (st.conditions || []).find(c => c.type === 'Available');
  if (progressing?.status === 'False' || available?.status === 'False') {
    return {
      status: 'error', readyReplicas: ready, replicas: st.replicas || 0,
      message: progressing?.reason || available?.reason || 'Deployment failed',
    };
  }
  return { status: 'deploying', readyReplicas: ready, replicas: st.replicas || 0 };
}

async function statusCustomBot(id) {
  const name = baseName(id);
  const dep = await apps.readNamespacedDeployment({ name, namespace: NAMESPACE });
  return summarizeDeployment(dep);
}

async function logsCustomBot(id, tailLines = 200) {
  const name = baseName(id);
  const pods = await core.listNamespacedPod({
    namespace: NAMESPACE, labelSelector: `app=${name}`,
  });
  const items = (pods?.items || [])
    .sort((a, b) => new Date(b.metadata.creationTimestamp) - new Date(a.metadata.creationTimestamp));
  if (!items.length) return { logs: '', pod: null };
  const pod = items[0];
  const logs = await core.readNamespacedPodLog({
    name: pod.metadata.name, namespace: NAMESPACE,
    container: 'bot', tailLines: Math.min(Math.max(tailLines, 1), 2000),
  });
  return { logs: typeof logs === 'string' ? logs : String(logs || ''), pod: pod.metadata.name };
}

module.exports = {
  available, applyCustomBot, removeCustomBot, restartCustomBot,
  statusCustomBot, logsCustomBot, baseName,
  NAMESPACE, BASE_DOMAIN, IMAGE_PREFIX,
};
