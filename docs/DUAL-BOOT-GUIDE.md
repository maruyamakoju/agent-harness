# Ubuntu 24.04 デュアルブート セットアップガイド

Windows 11 + RTX 4090 マシンへの Ubuntu デュアルブートインストール手順。

## 前提条件

- Windows 11 が稼働中のPCe
- RTX 4090 GPU
- ディスクに 200GB以上 の空き容量（C:71GB空き, G:563GB空き → **G:ドライブにインストール推奨**）
- 8GB以上のUSBメモリ
- 有線LANケーブル（推奨）

## Phase 1: Windows側の準備（所要: 30分）

### 1.1 重要データのバックアップ

```
# 万が一に備え、以下をバックアップ
- ドキュメント、デスクトップのファイル
- ブラウザのブックマーク
- SSH鍵（~/.ssh/）
- このプロジェクトのリポジトリ（GitHubにpush済みなら不要）
```

### 1.2 ディスクパーティションの縮小

**ディスク状況** (2025/02時点):
- C: 1.9TB (空き71GB) → 空き不足、縮小は厳しい
- E: (空き67GB)
- G: (空き563GB) → **★ ここを縮小してUbuntuに使う**

1. **Win + R** → `diskmgmt.msc` → Enter
2. **G:ドライブ** を右クリック → **ボリュームの縮小**
3. **縮小するサイズ**: 最低 200,000 MB（200GB）推奨 → 300GB推奨
   - Agent workspaceでDocker imageやgit cloneが大量に発生するため
4. 「縮小」をクリック → **未割り当て領域** が作成される

> **注**: C:は71GBしか空きがないため、C:の縮小は推奨しません。

### 1.3 BitLocker の無効化（有効な場合）

```
# 管理者PowerShell
manage-bde -status C:
# もし暗号化されていたら:
manage-bde -off C:
# 復号完了まで待つ（数十分かかる場合あり）
```

### 1.4 高速スタートアップの無効化

1. **コントロールパネル** → **電源オプション** → **電源ボタンの動作を選択する**
2. **現在利用可能ではない設定を変更します** をクリック
3. **高速スタートアップを有効にする** の **チェックを外す**
4. **変更の保存**

### 1.5 Ubuntu ISO & Rufus（準備済み）

デスクトップに以下が準備されている:
- `ubuntu-24.04.4-live-server-amd64.iso` (3.2GB)
- `rufus-4.6.exe`

### 1.6 ブータブルUSBの作成

1. **Rufus** (`rufus-4.6.exe`) を起動
2. USBメモリ（8GB以上）を選択
3. **ブートの種類**: `ubuntu-24.04.4-live-server-amd64.iso` を選択
4. **パーティション構成**: **GPT**
5. **ターゲットシステム**: **UEFI**
6. **スタート** → 書き込み完了まで待つ（約5分）
7. 完了後、USB-readyフォルダ（`Desktop/USB-ready/agent-harness/`）を **USBメモリの余りスペースにコピー**

### 1.7 agent-harness リポジトリ（push済み）

GitHubリポジトリ: https://github.com/maruyamakoju/agent-harness (private)

既にpush済み。Ubuntu側からclone可能。

## Phase 2: BIOS設定（所要: 5分）

1. PCを再起動
2. **DEL** または **F2** 連打でBIOS画面に入る
3. 以下を確認・変更:

| 設定項目 | 値 |
|---------|------|
| **Secure Boot** | Disabled |
| **Fast Boot** | Disabled |
| **Boot Order** | USB を最優先に |
| **UEFI Mode** | 有効（CSMは無効） |

4. **Save & Exit**

## Phase 3: Ubuntu インストール（所要: 15分）

1. USBメモリから起動 → **Install Ubuntu Server** を選択
2. 言語: **English** (サーバーなので英語推奨)
3. キーボード: **Japanese**
4. ネットワーク: 有線LANが自動認識されるはず → DHCP
5. ストレージ設定:

### ストレージ設定（重要）

**Custom storage layout** を選択:

| パーティション | サイズ | タイプ | マウント |
|-------------|--------|--------|---------|
| EFI (既存) | 100MB | EFI System | /boot/efi (既存を使用) |
| Ubuntu root | 残り全部 | ext4 | / |
| Swap | 16GB | swap | swap |

**注意**: Windows のパーティション（NTFS）には絶対に触らないこと！

6. ユーザー設定:
   - Your name: `agent`
   - Server's name: `agent-runner`
   - Username: `agent`
   - Password: 強力なパスワード

7. **Install OpenSSH server**: **チェックを入れる**
8. Featured Server Snaps: 何も選ばずに **Done**
9. インストール完了 → **Reboot Now** → USBメモリを抜く

## Phase 4: 起動確認

再起動後、GRUB メニューが表示される:
- **Ubuntu** ← こちらを選択
- **Windows Boot Manager** ← Windowsに戻りたい時

Ubuntu が起動したらログイン。

## Phase 5: エージェントシステムのセットアップ（所要: 15-30分）

### 方法A: USBにagent-harnessをコピー済みの場合（推奨）

```bash
# USBメモリをマウント (自動マウントされない場合)
sudo mkdir -p /media/agent/USB
sudo mount /dev/sdX1 /media/agent/USB  # sdX1はUSBのパーティション

# ワンショットセットアップ（全自動）
sudo bash /media/agent/USB/agent-harness/scripts/post-boot.sh
```

### 方法B: インターネットから直接

```bash
# ワンライナー（GitHubから直接）
curl -fsSL https://raw.githubusercontent.com/maruyamakoju/agent-harness/main/scripts/post-boot.sh | sudo bash
```

### 方法C: 手動ステップ

```bash
# 1. リポジトリをclone
git clone https://github.com/maruyamakoju/agent-harness.git ~/agent-harness

# 2. ブートストラップ実行
cd ~/agent-harness
sudo bash scripts/bootstrap.sh

# 3. .env を配置（USBからコピーまたは手動編集）
# .env は USB-ready/agent-harness/.env に事前作成済み

# 4. Docker build & start
docker compose build
docker compose up -d

# 5. Claude Code 認証
bash scripts/setup-claude-auth.sh
```

post-boot.sh が完了したら、画面の指示に従って:
1. `bash scripts/setup-claude-auth.sh` でClaude認証（ブラウザ必要）
2. `bash scripts/monitor.sh` でステータス確認
3. 最初のジョブ投入

## Phase 6: GRUB デフォルトをUbuntuに（24/7運用）

```bash
# GRUBのデフォルトをUbuntuに
sudo nano /etc/default/grub

# GRUB_DEFAULT=0  (Ubuntuが最初のエントリであることを確認)
# GRUB_TIMEOUT=5  (5秒待ってから自動起動)

sudo update-grub
```

これで電源投入時や再起動時に、自動的にUbuntuが起動する。
Windowsを使いたい場合は、起動時にGRUBメニューで選択する。

## トラブルシューティング

### NVIDIA ドライバが認識されない
```bash
# 再起動後に確認
nvidia-smi
# エラーなら:
sudo ubuntu-drivers autoinstall
sudo reboot
```

### GRUBメニューが表示されない
```bash
# Windows側でbcdeditを確認
# またはBIOS Boot OrderでUbuntuのEFIエントリを最優先に
```

### Windowsの時計がずれる
```bash
# Ubuntu側でRTCをローカルタイムに設定
timedatectl set-local-rtc 1
```

### SSH接続できない
```bash
sudo systemctl status sshd
sudo ufw status
# ポート22がALLOWになっているか確認
```
