#!/bin/zsh
# watch.sh：在 Mac 的終端機執行一次，放著不要關。
# Claude 改完程式碼後會在 .sync 資料夾放一個記號，這個腳本看到記號就上傳、等雲端編譯、把結果抓回來。
# 權杖只存在這個視窗的記憶體裡，關掉視窗就沒有了，不會寫進任何檔案。
cd "$(dirname "$0")/.." || exit 1
mkdir -p .sync
echo "請貼上 GitHub 權杖（github_pat_ 開頭），再按 Enter。貼上後畫面不會顯示任何字，這是正常的。"
read -rs GH_PAT
export GH_PAT
if [[ -z "$GH_PAT" ]]; then echo "沒有收到權杖，請重新執行。"; exit 1; fi
caffeinate -i -w $$ &
echo "收到。開始待命，這個視窗請放著不要關（可以縮到最小）。"
while true; do
  date '+%s' > .sync/alive
  if [[ -f .sync/trigger ]]; then
    rm -f .sync/trigger
    echo "$(date '+%H:%M:%S') 開始上傳並編譯…"
    /usr/bin/perl tools/sync.pl >> .sync/log.txt 2>&1
    echo "$(date '+%H:%M:%S') $(grep '^result=' .sync/done.txt 2>/dev/null | cut -d= -f2-)"
  fi
  sleep 3
done
