# Aztec Node (Testnet) – README

Script `aztec-node.sh` giúp bạn **cài đặt / chạy / nâng cấp** Aztec node (sequencer + archiver) trên Ubuntu theo cách **idempotent** (chạy lại an toàn). Script sẽ:
- Tự cài Docker & phụ thuộc cần thiết  
- Hỏi thông tin cấu hình lần đầu rồi **lưu vào `/opt/aztec/.env`**  
- **Tự derive `COINBASE`** từ `VALIDATOR_PRIVATE_KEY` (nếu bạn để trống)  
- Tạo `docker-compose.yml` & chạy container  
- Hỗ trợ **nâng cấp an toàn** Aztec CLI + Docker image

> **Lưu ý:** mạng sử dụng là **`testnet`** (không phải `alpha-testnet`).

---

## 1) Yêu cầu hệ thống

- Ubuntu 22.04/24.04 LTS (root/sudo)  
- 4 vCPU+, 8 GB RAM+, SSD khuyến nghị  
- Mạng mở cổng: `40400/tcp`, `40400/udp`, `8080/tcp` (UFW/Security Group)  
- **L1 RPC Sepolia (HTTPS) hỗ trợ EIP-4844**  
- **Beacon Sepolia (Consensus)** hợp lệ

---

## 2) Nguồn RPC/Beacon khuyến nghị

- **Sepolia RPC (HTTPS):** lấy ở **Ankr**  
  - Đăng ký tại: https://www.ankr.com/rpc/?utm_referral=xGC737eQXu  
  - Ví dụ endpoint:
    ```
    https://rpc.ankr.com/eth_sepolia
    ```
  > Hãy đảm bảo endpoint hỗ trợ **EIP-4844** (method `eth_blobBaseFee`). Nếu public endpoint/plan không hỗ trợ, hãy tạo API key riêng trên Ankr Dashboard và kiểm tra bằng lệnh `eth_blobBaseFee` trong phần debug bên dưới.

- **Sepolia Beacon (Consensus):** lấy ở **dRPC**  
  Ví dụ:  
  ```
  https://lb.drpc.org/ethereum/sepolia/beacon
  ```

---

## 3) Faucet – Nhận ETH Sepolia

Bạn cần **một ít ETH Sepolia** (làm phí L1) cho ví publish/coinbase.

- Dùng **Alchemy Sepolia Faucet** (có thể cần tài khoản; hạn mức theo ngày).  
- Có thể bổ sung từ các faucet cộng đồng khác.

**Kiểm tra số dư:**
```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getBalance","params":["0xYOUR_ADDRESS","latest"]}' \
  https://eth-sepolia.g.alchemy.com/v2/<YOUR_KEY> | jq -r .result
```

---

## 4) Cài & chạy script

> **Bước 0 (tuỳ chọn, nếu hệ thiếu):**
```bash
sudo apt-get update -y
sudo apt-get install -y gawk util-linux jq curl
```

**Bước 1 – Lưu script:**
```bash
git clone https://github.com/0xsyncroot/aztect-node-guide.git

cd aztect-node-guide

chmod +x aztec-node.sh
```

**Bước 2 – Cài & chạy lần đầu (sẽ hỏi biến, rồi lưu .env):**
```bash
sudo ./aztec-node.sh --install
```

**Bước 3 – Theo dõi log & kiểm tra tip L2:**
```bash
docker compose -f /opt/aztec/docker-compose.yml logs -fn 200

curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
  http://localhost:8080 | jq -r ".result.proven.number"
```

---

## 5) Cấu hình `.env` (được lưu tại `/opt/aztec/.env`)

Script sẽ tự hỏi & ghi các biến sau:

```env
ETHEREUM_RPC_URL=   # Sepolia RPC HTTPS (khuyến nghị Alchemy)
CONSENSUS_BEACON_URL=   # Sepolia Beacon (khuyến nghị dRPC)

VALIDATOR_PRIVATE_KEY=0x...   # 64 hex, cực kỳ bảo mật
COINBASE=0x...                # nếu trống, script sẽ derive từ private key
P2P_IP=                       # tự phát hiện

AZTEC_CLI_VERSION=1.2.0       # có thể đổi
AZTEC_IMAGE_TAG=latest        # có thể đổi (vd: v0.48.2)
AZTEC_LOG_LEVEL=info          # info/debug
```

> Bạn có thể chỉnh `.env` rồi chạy `--upgrade` để áp dụng.

---

## 6) Nâng cấp / Bảo trì

```bash
# Nâng cấp Aztec CLI + Docker image theo version trong .env
sudo ./aztec-node.sh --upgrade

# Đổi version rồi upgrade
sudo ./aztec-node.sh --set-version 1.2.3 v0.48.2
sudo ./aztec-node.sh --upgrade

# Khởi động lại container
sudo ./aztec-node.sh --restart

# Xem trạng thái
sudo ./aztec-node.sh --status

# Gỡ container (giữ data ~/.aztec)
sudo ./aztec-node.sh --uninstall
```

---

## 7) Kiểm tra nhanh & Debug

**Kiểm tra CLI & container:**
```bash
aztec --version
docker ps --filter "name=aztec-sequencer"
```

**Kiểm tra chainId Sepolia (thường `0xaa36a7`):**
```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"eth_chainId","params":[]}' \
  "$ETHEREUM_RPC_URL"
```

**Preflight: RPC có hỗ trợ EIP-4844?**
```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blobBaseFee","params":[]}' \
  "$ETHEREUM_RPC_URL"
# Nếu trả "method not found" ⇒ RPC KHÔNG hỗ trợ 4844 → đổi RPC (Alchemy/Infura)
```

**Xem log mới nhất:**
```bash
docker compose -f /opt/aztec/docker-compose.yml logs -fn 200
```

---

## 8) Cảnh báo thường gặp & Cách khắc phục

### A) `the method eth_blobBaseFee does not exist/is not available` (HTTP 400)
- **Nguyên nhân:** RPC Sepolia **không hỗ trợ EIP-4844** hoặc sai route.
- **Khắc phục:**
  - Dùng Alchemy Sepolia làm `ETHEREUM_RPC_URL`, hoặc
  - Với dRPC, bắt buộc path đúng: `https://lb.drpc.org/ethereum/sepolia/<KEY>` (không dùng `/sepolia/...` trần).

### B) `Cannot propose block ... since the committee does not exist on L1`
- **Ý nghĩa:** Node không thể propose vì **chưa có committee hợp lệ trên L1** hoặc bạn **chưa ở sequencer set**.
- **Khắc phục:**
  - Xác nhận compose đang chạy **`--network testnet`** (không phải `alpha-testnet`).
  - Hoàn tất **onboarding** để được thêm vào **sequencer set** của testnet.
  - Đảm bảo RPC/Beacon chuẩn và node đã sync.

### C) `PS1: unbound variable` khi cài CLI
- **Nguyên nhân:** `source ~/.bashrc` trong môi trường `set -u`.
- **Khắc phục:** Script đã vá để **không `source`**; chỉ `export PATH="/root/.aztec/bin:$PATH"`.
  Nếu cài tay:
  ```bash
  echo 'export PATH="$HOME/.aztec/bin:$PATH"' >> ~/.bashrc
  ```

### D) `Script đang chạy nơi khác (lock /var/lock/aztec-node.lock)`
- **Nguyên nhân:** Lần chạy trước chưa thoát sạch (installer từng mở “fresh shell”).
- **Khắc phục:**
  ```bash
  lsof /var/lock/aztec-node.lock || fuser -v /var/lock/aztec-node.lock
  # kill <PID> nếu còn, rồi:
  sudo rm -f /var/lock/aztec-node.lock
  sudo ./aztec-node.sh --upgrade
  ```

### E) `awk is a virtual package` (Ubuntu 24.04)
- **Nguyên nhân:** `awk` là gói ảo.
- **Khắc phục:**
  ```bash
  sudo apt-get install -y gawk util-linux
  ```

---

## 9) Vị trí file

- ENV: `/opt/aztec/.env`  
- Compose: `/opt/aztec/docker-compose.yml`  
- Dữ liệu node: `~/.aztec/testnet/data/`  
- Lock: `/var/lock/aztec-node.lock`

---

## 10) Bảo mật

- **Không chia sẻ `VALIDATOR_PRIVATE_KEY`**.  
- Dùng ví riêng cho node; chỉ nạp **đủ ETH Sepolia** để publish.  
- Giới hạn quyền truy cập máy chủ (SSH key, firewall, fail2ban…).

---

## 11) Câu lệnh hữu ích

```bash
# Cập nhật image + khởi chạy
docker compose -f /opt/aztec/docker-compose.yml pull
docker compose -f /opt/aztec/docker-compose.yml up -d

# Dừng & xoá container + volumes
docker compose -f /opt/aztec/docker-compose.yml down -v

# Kiểm tra health P2P
ss -lunpt | grep 40400
ss -ltnpt | grep 8080
```
