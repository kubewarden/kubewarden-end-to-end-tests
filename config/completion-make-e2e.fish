# Completions for 'make' command based on the e2e Makefile targets and variables.
# Using ~/.config/fish/completions/make.fish would override the built-in completions.
# To apply copy completion file to ~/.config/fish/conf.d/

# --- Predefine variables ---
set -l cluster_vars K3S= 'DRY=1' 'MTLS=1' 'KEEP=1'
set -l helmer_vars 'LATEST=1' 'APPCO=1' VERSION= CRDS_ARGS= CONTROLLER_ARGS= DEFAULTS_ARGS= APPCO_ARGS= CHARTS_LOCATION=

# # --- Cluster target variables ---
complete -k -c make -n '__fish_seen_subcommand_from cluster' -d 'Variable' -a "$cluster_vars"  -f

# --- Rancher target (inherits cluster vars) ---
complete -k -c make -n '__fish_seen_subcommand_from rancher' -d 'Variable' -a "RANCHER= $cluster_vars"  -f

# --- Install & Upgrade targets (inherit cluster vars) ---
complete -k -c make -n "__fish_seen_subcommand_from install" -d 'Variable' -a "$helmer_vars $cluster_vars"
complete -k -c make -n "__fish_seen_subcommand_from upgrade" -d 'Variable' -a "$helmer_vars"

# --- Test specific variables ---
complete -k -c make -n "__fish_seen_subcommand_from opentelemetry-tests.bats" -d 'Variable' -a "OTEL_OPERATOR=" -f
