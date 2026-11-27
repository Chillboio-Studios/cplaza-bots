#!/usr/bin/env bash
# CreatorPlaza custom-bot runner.
# Env (injected by the platform):
#   REPO_URL        https://github.com/owner/repo (public repos only)
#   BRANCH          git branch to clone (default: repo default branch)
#   LANGUAGE        python | nodejs | java | cpp
#   STARTUP_SCRIPT  shell command run inside the cloned repo
set -u

REPO_DIR=/app/repo

echo "[runner] cloning $REPO_URL (branch: ${BRANCH:-default})"
if ! git clone --depth 1 --branch "${BRANCH:-main}" "$REPO_URL" "$REPO_DIR" 2>/dev/null; then
  echo "[runner] branch '${BRANCH:-main}' not found — cloning default branch"
  rm -rf "$REPO_DIR"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR" || exit 1

case "${LANGUAGE:-}" in
  python)
    if [ -f requirements.txt ]; then
      echo "[runner] installing python requirements"
      pip install --no-cache-dir -r requirements.txt || echo "[runner] pip install failed — continuing"
    fi
    ;;
  nodejs)
    if [ -f package.json ]; then
      echo "[runner] installing node dependencies"
      if [ -f package-lock.json ]; then
        npm ci || npm install || true
      else
        npm install || true
      fi
    fi
    ;;
  java)
    if [ -f pom.xml ]; then
      echo "[runner] building maven project"
      mvn -q -DskipTests package || echo "[runner] mvn package failed — continuing"
    elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
      if [ -x ./gradlew ]; then
        echo "[runner] building gradle project"
        ./gradlew -q build -x test || echo "[runner] gradle build failed — continuing"
      else
        echo "[runner] gradle project without wrapper — install gradle in your startup script"
      fi
    fi
    ;;
  cpp) : ;; # compile/run via the startup script itself, e.g. g++ -O2 main.cpp -o bot && ./bot
esac

echo "[runner] executing startup script"
exec bash -c "$STARTUP_SCRIPT"
