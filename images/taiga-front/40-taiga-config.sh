#!/bin/sh
# Generate conf.json (from conf.json.template and the same environment variables as taigaio/taiga-front)
# and index.html (base href for TAIGA_SUBPATH) in /tmp/taiga-front. A conf.json mounted on
# /usr/share/nginx/html/conf.json is used as is.
set -eu

html=/usr/share/nginx/html
out=/tmp/taiga-front
mkdir -p "$out"

: "${ENABLE_SLACK:=false}" "${PUBLIC_REGISTER_ENABLED:=false}" "${ENABLE_GITHUB_AUTH:=false}"
: "${ENABLE_GITLAB_AUTH:=false}" "${ENABLE_OIDC_AUTH:=false}" "${ENABLE_GITHUB_IMPORTER:=false}"
: "${ENABLE_JIRA_IMPORTER:=false}" "${ENABLE_TRELLO_IMPORTER:=false}" "${DEFAULT_LANGUAGE:=en}" "${DEBUG:=false}"
: "${DEFAULT_LOGIN_ENABLED:=true}" "${OIDC_BUTTON_TEXT:=Login with SSO}" "${OIDC_BUTTON_LOGO:=}"
: "${TAIGA_URL:=}" "${TAIGA_WEBSOCKETS_URL:=}" "${TAIGA_SUBPATH:=}"
: "${GITHUB_CLIENT_ID:=}" "${GITLAB_CLIENT_ID:=}" "${GITLAB_URL:=}"

contribs=""
add() { contribs="${contribs:+$contribs,}\"plugins/$1/$1.json\""; }
[ "$ENABLE_SLACK" = true ] && add slack
if [ "$PUBLIC_REGISTER_ENABLED" = true ]; then
    [ "$ENABLE_GITHUB_AUTH" = true ] && add github-auth
    [ "$ENABLE_GITLAB_AUTH" = true ] && add gitlab-auth
fi
[ "$ENABLE_OIDC_AUTH" = true ] && add oidc-auth
CONTRIB_PLUGINS="[$contribs]"

export ENABLE_SLACK PUBLIC_REGISTER_ENABLED ENABLE_GITHUB_AUTH ENABLE_GITLAB_AUTH ENABLE_OIDC_AUTH \
    ENABLE_GITHUB_IMPORTER ENABLE_JIRA_IMPORTER ENABLE_TRELLO_IMPORTER DEFAULT_LANGUAGE DEBUG \
    DEFAULT_LOGIN_ENABLED OIDC_BUTTON_TEXT OIDC_BUTTON_LOGO TAIGA_URL TAIGA_WEBSOCKETS_URL TAIGA_SUBPATH \
    GITHUB_CLIENT_ID GITLAB_CLIENT_ID GITLAB_URL CONTRIB_PLUGINS

if [ -f "$html/conf.json" ]; then
    cp "$html/conf.json" "$out/conf.json"
else
    envsubst < "$html/conf.json.template" > "$out/conf.json"
fi
sed 's;<base href="/">;<base href="'"$TAIGA_SUBPATH"'/">;g' "$html/index.html" > "$out/index.html"
