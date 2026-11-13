#!/usr/bin/perl
# sync.pl：把這個資料夾的內容上傳到 GitHub、等雲端編譯完成、把結果抓回 .sync/
# 由 tools/watch.sh 呼叫（權杖從環境變數 GH_PAT 來，不會寫進任何檔案）。
# 只用 macOS 內建的 perl 和 curl，不需要安裝 git。
use strict;
use warnings;
use JSON::PP;
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(sha1_hex);
use File::Find;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Cwd qw(getcwd);

$| = 1;
my $REPO   = 'hotdogyong/note-app';
my $BRANCH = 'main';
my $TOKEN  = $ENV{GH_PAT} // '';
my $ROOT   = getcwd();
my $SYNC   = "$ROOT/.sync";
my $J      = JSON::PP->new->utf8;
my $TMP    = tempdir(CLEANUP => 1);
my $LIST   = (@ARGV && $ARGV[0] eq '--list');

sub stamp { my @t = localtime; return sprintf('%02d:%02d:%02d', $t[2], $t[1], $t[0]) }
sub bytes { my ($s) = @_; $s = '' unless defined $s; utf8::encode($s) if utf8::is_utf8($s); return $s }
sub logln { print stamp(), ' ', (map { bytes($_) } @_), "\n" }
sub write_file { my ($path, $data) = @_; open(my $fh, '>:raw', $path) or die "cannot write $path: $!"; print $fh $data; close $fh }
sub read_file { my ($path) = @_; open(my $fh, '<:raw', $path) or die "cannot read $path: $!"; local $/; my $d = <$fh>; close $fh; return $d }
sub status { my ($s) = @_; write_file("$SYNC/status.txt", stamp() . ' ' . bytes($s) . "\n") }

my %DONE;
sub finish {
    my ($ok, $result) = @_;
    my $text = "ok=$ok\nresult=" . bytes($result) . "\ntime=" . scalar(localtime) . "\n";
    for my $k (sort keys %DONE) { $text .= "$k=" . bytes($DONE{$k}) . "\n" }
    write_file("$SYNC/done.txt", $text);
    status($result);
    logln('結束：', $result);
    exit($ok ? 0 : 1);
}

my $n = 0;
sub api {
    my ($method, $path, $body) = @_;
    $n++;
    my $out = "$TMP/out$n";
    my @cmd = ('curl', '-sS', '-L', '--max-time', '180', '-X', $method, '-H', "\@$TMP/h", '-o', $out, '-w', '%{http_code}');
    if (defined $body) {
        my $bf = "$TMP/body$n";
        write_file($bf, $J->encode($body));
        push @cmd, '-H', 'Content-Type: application/json', '--data-binary', "\@$bf";
    }
    push @cmd, ($path =~ /^https:/ ? $path : "https://api.github.com/repos/$REPO$path");
    my $code = '';
    for my $try (1 .. 3) {
        my $p;
        if (!open($p, '-|', @cmd)) { finish(0, "找不到 curl：$!") }
        my $got = do { local $/; <$p> };
        close $p;
        $code = defined $got ? $got : '';
        last if $code =~ /^\d{3}$/ && $code ne '000' && $code !~ /^5/;
        logln("連線失敗（$code），5 秒後重試");
        sleep 5;
    }
    my $text = -e $out ? read_file($out) : '';
    my $json = eval { $J->decode($text) };
    return ($code, $json, $text);
}

sub need {
    my ($what, $code, $json, $text, @ok) = @_;
    return if grep { $_ eq $code } @ok;
    my $msg = (ref $json eq 'HASH' && defined $json->{message}) ? $json->{message} : substr($text, 0, 300);
    finish(0, "失敗：$what（HTTP $code）" . bytes($msg));
}

# ---- 1. 這個資料夾裡要上傳的檔案 ----
my %local;
find({ no_chdir => 1, wanted => sub {
    my $full = $File::Find::name;
    return if $full eq $ROOT;
    (my $rel = $full) =~ s{^\Q$ROOT\E/}{};
    if (-d $full) {
        if ($rel =~ m{^(\.sync|\.git|build|Payload|Support)$} || $rel =~ /\.xcodeproj$/) { $File::Find::prune = 1 }
        return;
    }
    return if $rel =~ m{(^|/)\.DS_Store$} || $rel =~ /\.ipa$/ || $rel =~ m{^(build\.log|errors\.txt|tail\.txt)$};
    return if $rel =~ m{(^|/)\._};
    $local{$rel} = $full;
}}, $ROOT);

my %sha;
for my $rel (keys %local) {
    my $data = read_file($local{$rel});
    $sha{$rel} = sha1_hex('blob ' . length($data) . "\0" . $data);
}
if ($LIST) { print "$sha{$_}  $_\n" for sort keys %local; exit 0 }

make_path($SYNC);
unlink "$SYNC/done.txt";
finish(0, '沒有權杖（GH_PAT 是空的）') if $TOKEN eq '';
finish(0, '沒有可上傳的檔案') unless %local;
write_file("$TMP/h", "Authorization: Bearer $TOKEN\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\nUser-Agent: note-app-sync\n");
chmod 0600, "$TMP/h";
status('開始上傳');

# ---- 2. GitHub 上目前的內容 ----
my ($c, $j, $t) = api('GET', "/git/ref/heads/$BRANCH");
if ($c eq '404' || $c eq '409') {
    logln('倉庫是空的，先建立第一個提交');
    ($c, $j, $t) = api('PUT', '/contents/README.md', { message => 'init', content => encode_base64("note-app\n", '') });
    need('建立第一個提交', $c, $j, $t, '201', '200');
    sleep 2;
    ($c, $j, $t) = api('GET', "/git/ref/heads/$BRANCH");
}
need('讀取 main 分支', $c, $j, $t, '200');
my $head = $j->{object}{sha};
($c, $j, $t) = api('GET', "/git/commits/$head");
need('讀取目前的提交', $c, $j, $t, '200');
my $head_tree = $j->{tree}{sha};
($c, $j, $t) = api('GET', "/git/trees/$head_tree?recursive=1");
need('讀取目前的檔案清單', $c, $j, $t, '200');
my %remote = map { $_->{path} => $_->{sha} } grep { $_->{type} eq 'blob' } @{ $j->{tree} || [] };

# ---- 3. 上傳有變的檔案 ----
my @entries;
my $uploaded = 0;
for my $rel (sort keys %local) {
    my $p = $rel;
    utf8::decode($p);
    if (!defined $remote{$p} || $remote{$p} ne $sha{$rel}) {
        my $data = read_file($local{$rel});
        my ($c2, $j2, $t2) = api('POST', '/git/blobs', { content => encode_base64($data, ''), encoding => 'base64' });
        need("上傳 $rel", $c2, $j2, $t2, '201');
        logln("警告：$rel 的指紋不一致") if $j2->{sha} ne $sha{$rel};
        $sha{$rel} = $j2->{sha};
        $uploaded++;
        logln("已上傳 $rel");
    }
    push @entries, { path => $p, mode => '100644', type => 'blob', sha => $sha{$rel} };
}
($c, $j, $t) = api('POST', '/git/trees', { tree => \@entries });
need('建立檔案清單', $c, $j, $t, '201');
my $tree = $j->{sha};
if ($tree eq $head_tree && !-e "$SYNC/force") {
    $DONE{sha} = $head;
    finish(1, '沒有變更，不用上傳');
}

my $message = -e "$SYNC/message.txt" ? read_file("$SYNC/message.txt") : 'update';
utf8::decode($message);
$message =~ s/\s+\z//;
$message = 'update' if $message eq '';
($c, $j, $t) = api('POST', '/git/commits', { message => $message, tree => $tree, parents => [$head] });
need('建立提交', $c, $j, $t, '201');
my $commit = $j->{sha};
($c, $j, $t) = api('PATCH', "/git/refs/heads/$BRANCH", { sha => $commit });
need('更新 main 分支', $c, $j, $t, '200');
$DONE{sha} = $commit;
$DONE{uploaded} = $uploaded;
logln("已上傳 $uploaded 個檔案，提交 $commit");
status('已上傳，等待雲端編譯');

# ---- 4. 等雲端編譯 ----
my $deadline = time + 50 * 60;
my $started  = time;
my $run;
while (time < $deadline) {
    sleep 15;
    my ($c3, $j3, $t3) = api('GET', "/actions/runs?head_sha=$commit&per_page=5");
    next unless $c3 eq '200' && ref $j3 eq 'HASH';
    my @runs = @{ $j3->{workflow_runs} || [] };
    if (!@runs) {
        finish(0, '上傳成功，但 5 分鐘內沒有開始編譯（Actions 可能沒有啟用）') if time - $started > 300;
        status('已上傳，等待雲端編譯開始');
        next;
    }
    $run = $runs[0];
    status("雲端編譯中：$run->{status}（已經 " . int((time - $started) / 60) . ' 分鐘）');
    last if $run->{status} eq 'completed';
}
finish(0, '等了 50 分鐘編譯還沒結束') unless $run && $run->{status} eq 'completed';
$DONE{conclusion} = $run->{conclusion} // '';
$DONE{run_url}    = $run->{html_url} // '';
$DONE{run_id}     = $run->{id} // '';

# ---- 5. 把結果抓回來 ----
make_path("$SYNC/result");
for my $f (qw(status.txt errors.txt tail.txt)) {
    my ($c4, $j4, $t4) = api('GET', "/contents/$f?ref=ci-results");
    if ($c4 eq '200' && ref $j4 eq 'HASH' && defined $j4->{content}) {
        write_file("$SYNC/result/$f", decode_base64($j4->{content}));
    } else {
        write_file("$SYNC/result/$f", "(no $f, HTTP $c4)\n");
    }
}
my ($c5, $j5, $t5) = api('GET', "/actions/runs/$run->{id}/jobs");
my $jobs = '';
if ($c5 eq '200' && ref $j5 eq 'HASH') {
    for my $job (@{ $j5->{jobs} || [] }) {
        $jobs .= "job $job->{name}: " . ($job->{conclusion} // '') . "\n";
        for my $step (@{ $job->{steps} || [] }) {
            $jobs .= "  step $step->{number} $step->{name}: " . ($step->{conclusion} // '') . "\n";
        }
        my ($c6, $j6, $t6) = api('GET', "/actions/jobs/$job->{id}/logs");
        write_file("$SYNC/result/job-log.txt", $c6 eq '200' ? $t6 : "(no log, HTTP $c6)\n");
    }
} else {
    $jobs = "(no jobs, HTTP $c5)\n";
}
write_file("$SYNC/result/jobs.txt", bytes($jobs));

# ---- 6. 成功的話把安裝檔下載到「安裝檔」資料夾 ----
if (($run->{conclusion} // '') eq 'success') {
    my ($c7, $j7, $t7) = api('GET', '/releases/tags/latest');
    my $url = (ref $j7 eq 'HASH' && $j7->{assets} && @{ $j7->{assets} }) ? $j7->{assets}[0]{browser_download_url} : '';
    if ($c7 eq '200' && $url) {
        my $dir = "$ROOT/../安裝檔";
        make_path($dir);
        # 檔名帶版本號（從 ContentView.swift 的 appVersion 讀），同一版再編一次就加 -b2、-b3，不蓋掉舊的
        my $ver = 'unknown';
        if (-e "$ROOT/Sources/ContentView.swift" && read_file("$ROOT/Sources/ContentView.swift") =~ /let appVersion = "([^"]+)"/) { $ver = $1 }
        my $name = "NoteApp-$ver.ipa";
        my $k = 1;
        while (-e "$dir/$name") { $k++; $name = "NoteApp-$ver-b$k.ipa" }
        my $rc = system('curl', '-sS', '-L', '--max-time', '600', '-o', "$dir/$name", $url);
        $DONE{ipa} = $rc == 0 ? "安裝檔/$name" : "下載失敗（$rc）";
    } else {
        $DONE{ipa} = "找不到安裝檔（HTTP $c7）";
    }
    finish(1, '編譯成功');
}
finish(0, '編譯失敗（錯誤在 .sync/result/errors.txt）');
