# gazelle:sh_dynamic_dep ../app/lib/extra/*
for f in "$APP"/lib/extra/*; do . "$f"; done
echo "$REPO/docs/GUIDE.md is not read: only tests have their references read"
