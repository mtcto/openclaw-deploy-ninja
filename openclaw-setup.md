# Skill: openclaw-setup

**Description:** (opencode - Skill) An automated end-to-end setup agent for installing, isolating, and configuring OpenClaw on macOS/Linux. It handles directory isolation (including external drive compatibility), Node.js environment bundling, system daemon management, UI exposure, and comprehensive model configuration (native OAuth, API keys, or API proxy gateways with complex fallback strategies).

## Triggers
- "install openclaw"
- "setup openclaw for me"
- "configure my openclaw models"
- "help me deploy openclaw locally"

## Context
OpenClaw is a powerful agentic platform. Its default installation can sometimes conflict with system Node versions or leave configurations scattered. This skill provides a "clean room" installation approach (using `install-cli.sh`) into a dedicated directory. It natively supports installing to external drives (like USBs or secondary partitions) and handles the macOS launchd permission errors elegantly. It also provides an interactive, robust model setup sequence that handles all tiers of users.

## Workflow

### Phase 1: Environment Installation
Use the `question` tool to ask the user about their installation preference:

1. **Ask for installation location**:
   - Option A: "Install to default macOS drive (e.g., `~/.openclaw`)"
   - Option B: "Install to an external drive or custom path"
2. **If Option B is selected**:
   - Ask the user to provide the exact absolute path of the external drive/custom directory (e.g., `/Volumes/MyDrive/openclaw`).
3. **Execute Installation**:
   - Let `<target_dir>` be the user's chosen path (or `~/.openclaw` for default).
   - Use `curl -fsSL https://openclaw.ai/install-cli.sh | bash -s -- --prefix <target_dir>`
   - This ensures a bundled, architecture-specific Node.js (v22+) is automatically downloaded (fully supporting both Intel x86_64 and Apple Silicon ARM64 Macs). Users do NOT need to pre-install Node.js or any other dependencies—it is a 100% self-contained setup.
4. **Environment Variable Injection**:
   - Append `export PATH="<target_dir>/bin:$PATH"` to `~/.zshrc` and `~/.bashrc`.
5. **Configuration Isolation**:
   - Move existing data (if any) to `<target_dir>/conf`.
   - Append `export OPENCLAW_STATE_DIR="<target_dir>/conf"` to `~/.zshrc` and `~/.bashrc`.

### Phase 2: Daemon & Service Management
1. **Handle macOS Launchd External Volume Restrictions (Conditional)**:
   - **Important Rule**: If and ONLY IF the user chose to install to an external volume (a path starting with `/Volumes/` on macOS), macOS `launchd` will throw `Exit Code 78` because it refuses to write `StandardOutPath` logs to external drives. You must patch the log paths.
2. **Installation Sequence**:
   - Run: `openclaw gateway install`
   - *If on macOS AND on an external volume, run the following three commands (Skip this for Linux or internal Mac drives):*
     - `sed -i '' 's|/Volumes/.*/logs/gateway.log|/tmp/openclaw-gateway.log|g' ~/Library/LaunchAgents/ai.openclaw.gateway.plist`
     - `sed -i '' 's|/Volumes/.*/logs/gateway.err.log|/tmp/openclaw-gateway.err.log|g' ~/Library/LaunchAgents/ai.openclaw.gateway.plist`
     - `launchctl bootout gui/$UID/ai.openclaw.gateway` (ignore errors if not loaded)
     - `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/ai.openclaw.gateway.plist`
3. **Start & Verify**:
   - Run: `openclaw gateway start`
   - Run `openclaw status` to ensure the daemon is running (state active) and the dashboard is accessible at `http://127.0.0.1:18789`.
   - *Note to user: Advise them that if they ever stop the service (`openclaw gateway stop`), they should wake it up using `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/ai.openclaw.gateway.plist` followed by `openclaw gateway start`, rather than running `install` again (which would overwrite the plist log fix).*

### Phase 3: Model & Provider Configuration
You must present the user with **three distinct choices** for how they want to configure their AI models. Use the `question` tool to ask them:

**Choice A: I have an official ChatGPT/Claude Subscription (OAuth / Web Login)**
- **Action**: Use the interactive onboarding wizard to authenticate without API keys.
- **Commands**:
  - For ChatGPT: `openclaw onboard --auth-choice openai-codex`
  - For Claude: `openclaw onboard --auth-choice claude-cli`
- *Note: Warn the user that if they use proxy software like Shadowrocket in TUN mode, the OAuth callback might be blocked by OpenClaw's SSRF protection. Advise them to use HTTP proxy mode during login.*

**Choice B: I have official API Keys (Direct Provider)**
- **Action**: Configure direct provider keys.
- **Commands**:
  - `openclaw onboard --auth-choice openai-api-key` (or anthropic, gemini, etc.)
  - Alternatively, use raw JSON patching: `openclaw config set agents.defaults.model.primary "anthropic/claude-3-5-sonnet-20241022"` and inject the key into `models.providers`.

**Choice C: I use a third-party API Proxy / Gateway (e.g., NewAPI, OneAPI)**
- **Action**: This is for users who buy aggregated API keys from third-party sites.
- **Prompt User for Details**: 
  - *Example prompt: "Please provide your proxy details. Example: BaseURL = 'http://api.proxy.com/v1', API Key = 'sk-xxxx'."*
- **Commands**: Use JSON injection to set up a custom provider and a robust fallback strategy.
  ```json
  {
    "models": {
      "providers": {
        "custom-proxy": {
          "baseUrl": "<USER_BASE_URL>",
          "apiKey": "<USER_API_KEY>",
          "api": "openai-completions",
          "models": [
            {"id": "glm-5", "name": "GLM 5"},
            {"id": "claude-3-5-sonnet", "name": "Claude 3.5 Sonnet"}
          ]
        }
      }
    },
    "agents": {
      "defaults": {
        "model": {
          "primary": "custom-proxy/claude-3-5-sonnet",
          "fallbacks": ["custom-proxy/glm-5"]
        }
      }
    }
  }
  ```

### Phase 4: Finalization
1. Restart the gateway: `openclaw gateway restart`.
2. Provide the user with their personalized Web UI link.
   - Run `openclaw dashboard --no-open` to generate the URL with the authentication token attached.
   - Output the URL clearly: `http://127.0.0.1:18789/#token=...`
