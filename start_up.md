# 🚀 Bimip Server Setup & Configuration Guide

## 1. Introduction

**Bimip (Binary Interface for Messaging and Internet Protocol)** is a high-performance, real-time communication protocol designed for distributed systems.
It supports **WebSocket-based communication**, **state synchronization**, and **adaptive network awareness** with flexible configuration.

This guide walks you through how to install, configure, and start the Bimip server in a production environment.

---

## 2. Installation

### 2.1 Prerequisites

Before starting, ensure the following are installed on your system:

- **Erlang/OTP 27+**
- **Elixir 1.18+**
- **OpenSSL**
- **Linux/macOS shell access (recommended)**

---

### 2.2 Download Bimip Release

Download or copy your release build into your preferred directory:

```bash
sudo mkdir -p /opt/bimip
sudo cp -r bimip_release /opt/bimip/
cd /opt/bimip
```

Your release folder should look like:

```
/opt/bimip/
├── bin/
│   └── bimip
├── lib/
├── releases/
└── erts-<version>/
```

---

## 3. Directory Setup

Bimip expects keys and runtime configuration to be available on your system.

### 3.1 Create a Keys Directory

```bash
sudo mkdir -p /etc/bimip/keys
```

### 3.2 Add Your Keys

Place your SSL and JWT keys in `/etc/bimip/keys/`:

```
/etc/bimip/keys/
├── cert.pem
├── key.pem
└── public.pem
```

- `cert.pem`: TLS Certificate
- `key.pem`: TLS Private Key
- `public.pem`: JWT public key (for token verification)

---

## 4. Configuration

Bimip uses **environment variables** for all runtime configuration.
This allows flexibility without editing source files.

### 4.1 Create a `.env` File (Recommended)

Create a file named `.env` inside `/opt/bimip/` with the following content:

```bash
# Bimip Configuration
export BIMIP_PORT=4001
export BIMIP_SECURE_TLS=true
export BIMIP_CERT_FILE=/etc/bimip/keys/cert.pem
export BIMIP_KEY_FILE=/etc/bimip/keys/key.pem
export BIMIP_PUBLIC_KEY_PATH=/etc/bimip/keys/public.pem

# PubSub topic
export BIMIP_TOPIC=default

# Adaptive Network Config
export BIMIP_PING_INTERVAL=10000
export BIMIP_MAX_DELAY=120
export BIMIP_PONG_RETRIES=3

# Queue Limits
export BIMIP_MAX_QUEUE=1000
```

Then load the environment:

```bash
source .env
```

---

### 4.2 Custom Configuration

You can override any setting by updating your `.env` file or exporting new values, for example:

```bash
export BIMIP_PORT=8080
```

Then restart the server.

---

## 5. Starting the Server

To start Bimip:

```bash
./bin/bimip start
```

To stop it:

```bash
./bin/bimip stop
```

To run it in foreground (for debugging):

```bash
./bin/bimip foreground
```

---

## 6. Logs and Monitoring

Logs are stored in:

```
/opt/bimip/log/
```

You can also view real-time logs:

```bash
tail -f /opt/bimip/log/erlang.log.1
```

---

## 7. Updating Configuration

If you need to change configuration (e.g., port, key paths):

1. Edit the `.env` file
2. Re-run `source .env`
3. Restart the server:

   ```bash
   ./bin/bimip restart
   ```

---

## 8. Troubleshooting

| Issue                    | Cause                              | Solution                                  |
| ------------------------ | ---------------------------------- | ----------------------------------------- |
| Server not starting      | Missing or invalid cert/key file   | Verify `/etc/bimip/keys` paths            |
| Port already in use      | Another app is using the same port | Change `BIMIP_PORT` and restart           |
| JWT validation failed    | Invalid or mismatched public key   | Replace `public.pem` with the correct key |
| Environment not applying | Variables not loaded               | Run `source .env` before starting         |

---

## 9. Summary

✅ **Install** the release
✅ **Configure** using environment variables
✅ **Place keys** in `/etc/bimip/keys/`
✅ **Start the app** using `./bin/bimip start`

---

Would you like me to brand this version (add your logo, website footer, and section numbering for web publishing)?
It’ll look like a polished developer doc ready for your Bimip website.

verify the file
paulaigbokhaiolukayode@USERs-MacBook-Pro bimip % echo $BIMIP_PUBLIC_KEY_PATH
/etc/bimip/keys/public.pem

Absolutely — here’s a **user-focused installation guide** for **Bimip 1.0.0 Release**, modeled after Kafka-style ease of use. This assumes the user is downloading the **pre-built release**, not building from source.

---

# **Bimip 1.0.0 Release – User Installation Guide**

Bimip is a self-contained Elixir/BEAM application, packaged with all necessary dependencies. Users do **not** need Erlang or Elixir installed to run the release.

---

## **1. Download the Release**

1. Go to the Bimip release page or distribution link.
2. Download the release archive for your platform:

   - Linux/macOS: `bimip-1.0.0-release.tar.gz`
   - Windows: `bimip-1.0.0-release.zip`

3. Extract it to a location of your choice:

   - **Linux/macOS:**

     ```bash
     tar -xzf bimip-1.0.0-release.tar.gz -C /opt
     ```

   - **Windows:**
     Use Explorer or PowerShell:

     ```powershell
     Expand-Archive .\bimip-1.0.0-release.zip -DestinationPath C:\Bimip
     ```

Your folder structure will look like this:

```
bimip-1.0.0-release/
├── lib/              # Application libraries
├── rel/              # Release scripts and binaries
│   └── bin/
│       └── bimip     # Executable binary
└── tmp/              # Temporary runtime files
```

---

## **2. Configure Environment Variables**

To run `bimip` from anywhere:

### **Linux / macOS**

1. Open your shell profile:

   ```bash
   vim ~/.bashrc    # Linux
   vim ~/.zshrc     # macOS (Zsh)
   ```

2. Add the following lines:

   ```bash
   export BIMIP_BUILD_DIR="/opt/bimip/bimip-1.0.0-release/rel"
   export PATH="$BIMIP_BUILD_DIR/bin:$PATH"
   ```

3. Apply the changes:

   ```bash
   source ~/.bashrc   # Linux
   source ~/.zshrc    # macOS
   ```

### **Windows**

1. Open **System Properties → Advanced → Environment Variables**.

2. Add a new **User Variable**:

   ```
   Name: BIMIP_BUILD_DIR
   Value: C:\Bimip\bimip-1.0.0-release\rel
   ```

3. Edit the **Path** variable and add:

   ```
   %BIMIP_BUILD_DIR%\bin
   ```

---

## **3. Running Bimip**

Once the PATH is configured, you can start the application from anywhere:

```bash
bimip start      # Start Bimip in the background
bimip stop       # Stop the running instance
bimip restart    # Restart Bimip
bimip attach     # Attach to the running console
```

**Example:**

```bash
$ bimip start
🚀 Starting bimip...
```

---

## **4. Optional: Configure Environment**

If you have custom environment variables for Bimip, create a file called `bimip.env`:

```bash
BIMIP_PORT=4001
BIMIP_PUBLIC_KEY_PATH=/etc/bimip/keys/public.pem
BIMIP_SIGNING_ALG=RS256
```

Then point Bimip to load it at startup:

```bash
source /opt/bimip/bimip-1.0.0-release/bimip.env
```

---

## **5. Notes**

- **No Erlang/Elixir required**: The release is self-contained.
- **Permissions**: Ensure the `bin/bimip` binary is executable (`chmod +x bin/bimip` on Linux/macOS).
- **Logs**: Bimip creates runtime logs in the `tmp/` directory inside the release folder.
- **Upgrades**: Download the new release, extract to a new folder, update `BIMIP_BUILD_DIR` if needed.

---

This setup mirrors Kafka’s user installation experience: **download → extract → set PATH → run**.

---

If you want, I can also **write a one-liner “auto-setup script”** that users can just run to set the environment variables and make `bimip start` work immediately on Linux/macOS.

Do you want me to do that?

export BIMIP_BUILD_DIR="/Users/paulaigbokhaiolukayode/Documents/Applications/bimip/\_build/prod/rel/bimip"
export PATH="$BIMIP_BUILD_DIR/bin:$PATH"

# --- Connection config ---

export BIMIP_SECURE_TLS=false
export BIMIP_CERT_FILE="priv/cert.pem"
export BIMIP_KEY_FILE="priv/key.pem"
export BIMIP_PORT=4001
export BIMIP_RESOURCE_PATH="/application/development"
export BIMIP_IDLE_TIMEOUT=60000

# --- PubSub topic ---

export BIMIP_TOPIC="default"

# --- JWT / Key configuration ---

export BIMIP_PUBLIC_KEY_PATH="/etc/bimip/keys/public.pem"
export BIMIP_SIGNING_ALG="RS256"

# --- Adaptive Ping/Pong ---

export BIMIP_PING_INTERVAL=10000
export BIMIP_MAX_DELAY=120
export BIMIP_PONG_RETRIES=3
export BIMIP_MAX_MISSED_PINGS=6

# --- Device State Change ---

export BIMIP_DEVICE_STALE=600
export BIMIP_DEVICE_FORCE_CHANGE=300

# --- Server State Change ---

export BIMIP_SERVER_STALE=600
export BIMIP_SERVER_FORCE_CHANGE=120

# --- Queue ---

export BIMIP_MAX_QUEUE=1000

# --- Node/Cluster configuration (important for distributed nodes) ---

export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=bimip@wsone.local
export RELEASE_COOKIE=mysecret

echo $RELEASE_DISTRIBUTION
echo $RELEASE_NODE
echo $RELEASE_COOKIE

Got it! We can test clustering with **two `bimip` nodes** using `bimip start` (not plain IEx). Here’s the clean way to do it on **one machine** for testing purposes:

---

### 1️⃣ Clean your release

```bash
rm -rf _build/prod
MIX_ENV=prod mix release
```

---

### 2️⃣ Set hostnames in `/etc/hosts` (temporary for testing)

```text
127.0.0.1   wsone.local
127.0.0.1   wstwo.local
```

You already have this, so we’re good.

---

### 3️⃣ Start the first node (`wsone`) with `bimip start_iex`

```bash
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=bimip@wsone.local
export RELEASE_COOKIE=mysecret

_build/prod/rel/bimip/bin/bimip start_iex
```

Check it in the CLI:

```elixir
Node.self()
# :"bimip@wsone.local"
```

---

### 4️⃣ Start the second node (`wstwo`) **in a separate terminal** with a different node name

```bash
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=bimip@wstwo.local
export RELEASE_COOKIE=mysecret

_build/prod/rel/bimip/bin/bimip start_iex
```

Check:

```elixir
Node.self()
# :"bimip@wstwo.local"
```

---

### 5️⃣ Connect the nodes

From **any node** CLI:

```elixir
Node.connect(:"bimip@wsone.local")
Node.list()
# Should show [:bimip@wsone.local] on the wstwo node
```

---

✅ **Important points:**

- Each node **must have a unique name** (`bimip@wsone.local` vs `bimip@wstwo.local`).
- Both nodes must **share the same cookie**.
- Use `start_iex` for testing; `start` (daemon mode) will not show interactive output, so you can’t manually check connection.
- You **cannot run two nodes with the same name** or same cookie in the same shell/terminal.

---

I can also give you a **ready-to-copy script** that starts **two `bimip` nodes in two terminals** and automatically connects them so you can test clustering immediately.

Do you want me to do that?

name"
iex(bimip@wsone.local)2> System.get_env("RELEASE_NODE")
"bimip@wsone.local"
iex(bimip@wsone.local)3> System.get_env("RELEASE_COOKIE")
"mysecret"
iex(bimip@wsone.local)4> System.get_env("RELEASE_DISTRIBUTION")
"name"
iex(bimip@wsone.local)5> System.get_env("RELEASE_DISTRIBUTION")
"name"
iex(bimip@wsone.local)6>

# Bimip Configuration

export BIMIP_PORT=4001
export BIMIP_SECURE_TLS=true
export BIMIP_CERT_FILE=/etc/bimip/keys/cert.pem
export BIMIP_KEY_FILE=/etc/bimip/keys/key.pem
export BIMIP_PUBLIC_KEY_PATH=/etc/bimip/keys/public.pem

# PubSub topic

export BIMIP_TOPIC=default

# Adaptive Network Config

export BIMIP_PING_INTERVAL=10000
export BIMIP_MAX_DELAY=120
export BIMIP_PONG_RETRIES=3

# --- Connection config ---

export BIMIP_SECURE_TLS=false
export BIMIP_CERT_FILE="priv/cert.pem"
export BIMIP_KEY_FILE="priv/key.pem"
export BIMIP_PORT=4001
export BIMIP_RESOURCE_PATH="/application/development"
export BIMIP_IDLE_TIMEOUT=60000

# --- PubSub topic ---

export BIMIP_TOPIC="default"

# --- JWT / Key configuration ---

export BIMIP_PUBLIC_KEY_PATH="/etc/bimip/keys/public.pem"
export BIMIP_SIGNING_ALG="RS256"

# --- Adaptive Ping/Pong ---

export BIMIP_PING_INTERVAL=10000
export BIMIP_MAX_DELAY=120
export BIMIP_PONG_RETRIES=3
export BIMIP_MAX_MISSED_PINGS=6

# --- Device State Change ---

export BIMIP_DEVICE_STALE=600
export BIMIP_DEVICE_FORCE_CHANGE=300

# --- Server State Change ---

export BIMIP_SERVER_STALE=600
export BIMIP_SERVER_FORCE_CHANGE=120

# --- Queue ---

export BIMIP_MAX_QUEUE=1000

# --- Node/Cluster configuration (important for distributed nodes) ---

export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=bimip@wsone.local
export RELEASE_COOKIE=mysecret

Yes — Elixir/Erlang **can use local IPs** to connect nodes in a cluster, but there are a few caveats. Let me break it down clearly.

---

## 1️⃣ Node Names and IPs

In distributed Erlang, a node name is either:

1. **Short name (`sname`)**

   ```
   iex --sname bimip
   ```

   - Only works on the **same host** or LAN using local hostnames.
   - Automatically resolves to something like `bimip@hostname.local`.

2. **Long name (`name`)**

   ```
   iex --name bimip@192.168.1.10
   ```

   - Required if nodes are on **different hosts or using IPs**.
   - Full node name includes the IP/hostname after the `@`.
   - Must match exactly on all nodes when connecting.

> ⚠️ Important: You cannot mix `sname` and `name` in the same cluster.

---

## 2️⃣ Using Local IPs for a cluster

You **can** use `127.0.0.1` or `localhost` if:

- Both nodes are running on the **same machine**.
- You give each node a **different name**.

Example:

```bash
# Node 1
iex --name bimip1@127.0.0.1 --cookie mysecret

# Node 2
iex --name bimip2@127.0.0.1 --cookie mysecret
```

Then inside Node 2:

```elixir
Node.connect(:"bimip1@127.0.0.1")
```

✅ Both nodes will see each other.

---

## 3️⃣ Why `bimip start` may fail

The release script often hardcodes `RELEASE_NODE` or uses `sname`, so even if you pass `--name bimip@127.0.0.1`, the running node may still start as `bimip@hostname.local`.
This prevents the connection because **names don’t match exactly**.

**Solution:** Override `RELEASE_NODE` explicitly with:

```bash
export RELEASE_NODE=bimip1@127.0.0.1
export RELEASE_COOKIE=mysecret
_build/prod/rel/bimip/bin/bimip start_iex
```

Do the same for the second node with `bimip2@127.0.0.1`.

---

## 4️⃣ Key points

- Each node must have a **unique node name** even on the same machine.
- Use **long names** (`--name`) with IP if you want IP-based clustering.
- Ensure **cookie matches** for nodes to connect.
- Check `/etc/hosts` if using hostnames — it must resolve correctly.

---

If you want, I can give you a **ready-to-run setup for two nodes on the same Mac using 127.0.0.1** that will connect automatically with `bimip start_iex` without editing hostnames or env files.

Do you want me to do that?
