FROM mcr.microsoft.com/devcontainers/base:ubuntu

# [Option 1] Basic node and tooling setup
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    ripgrep \
    unzip \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# [Option 2] Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# [Option 3] Python and Node are installed via devcontainer features
# (github/codespaces-features handles node and python in the features)

USER vscode