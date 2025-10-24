# Bimip

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `bimip` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bimip, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/bimip>.

Exactly 👍 — that’s the idea **if you want users (or yourself in production)** to manage their own keys outside the app folder.

Let me break it down clearly 👇

---

### 🧩 Why move the key?

When you build a release (`mix release`), the `_build/prod` folder becomes a **self-contained** copy of your app.
If your key lives inside `priv/keys/`, it gets baked **into** the release folder — meaning:

- Each new release would carry the same key.
- It’s harder to rotate or replace the key later.
- It’s not flexible for users who want to plug in their own public key.

So, by moving it **outside** (e.g. `/etc/bimip/keys/public.pem`), you decouple your app from the key file.

---

### 🛠️ How to do it (step by step)

#### 1. Create a directory on your system for the key

```bash
sudo mkdir -p /etc/bimip/keys
```

#### 2. Move your current key there

```bash
sudo mv priv/keys/public.pem /etc/bimip/keys/public.pem
```

#### 3. Change permissions (so your app can read it)

```bash
sudo chmod 644 /etc/bimip/keys/public.pem
```

---

### 🧠 4. Tell your app where to find it

Edit your `config/runtime.exs` and add this logic:

```elixir
import Config

config :bimip, :jwt,
  public_key_path: System.get_env("BIMIP_PUBLIC_KEY_PATH") || "/etc/bimip/keys/public.pem",
  signing_algorithm: "RS256"
```

Then export the path before running the app (optional, if you want flexibility):

```bash
export BIMIP_PUBLIC_KEY_PATH=/etc/bimip/keys/public.pem
```

Now, when you run:

```bash
./bimip start
```

it will load the key from the system directory — not from inside the build.

---

export BIMIP_PUBLIC_KEY_PATH=/etc/bimip/keys/public.pem
export BIMIP_CERT_FILE=/etc/bimip/keys/cert.pem
export BIMIP_KEY_FILE=/etc/bimip/keys/key.pem
export BIMIP_PORT=4040
