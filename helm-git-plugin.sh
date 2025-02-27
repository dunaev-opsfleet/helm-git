#!/usr/bin/env sh

# See Helm plugins documentation: https://docs.helm.sh/using_helm/#downloader-plugins

set -e

readonly bin_name="helm-git"
readonly allowed_protocols="https http file ssh"
readonly url_prefix="git+"

readonly error_invalid_prefix="Git url should start with '$url_prefix'. Please check helm-git usage."
readonly error_invalid_protocol="Protocol not allowed, it should match one of theses: $allowed_protocols."

debug=0
if [ "$HELM_GIT_DEBUG" = "1" ]; then
  debug=1
fi

export TMPDIR="${TMPDIR:-/tmp}"
## Tooling

string_starts() { [ "$(echo "$1" | cut -c 1-${#2})" = "$2" ]; }
string_ends() { [ "$(echo "$1" | cut -c $((${#1} - ${#2} + 1))-${#1})" = "$2" ]; }
string_contains() { echo "$1" | grep -q "$2"; }
path_join() { echo "${1:+$1/}$2" | sed 's#//#/#g'; }

## Logging

debug() {
  [ $debug = 1 ] && echo "Debug in plugin '$bin_name': $*" >&2
  return 0
}

error() {
  echo "Error in plugin '$bin_name': $*" >&2
  exit 1
}

warning() {
  echo "Warning in plugin '$bin_name': $*" >&2
}

## Functions

# git_try(git_repo)
git_try() {
  _git_repo=$1

  GIT_TERMINAL_PROMPT=0 git ls-remote "$_git_repo" --refs >&2 || return 1
}

# git_checkout(sparse, target_path, git_repo, git_ref, git_path)
git_checkout() {
  _sparse=$1
  _target_path=$2
  _git_repo=$3
  _git_ref=$4
  _git_path=$5

  cd "$_target_path" >&2
  git init --quiet
  git config pull.ff only
  git remote add origin "$_git_repo" >&2
  if [ "$_sparse" = "1" ]; then
    git config core.sparseCheckout true
    [ -n "$_git_path" ] && echo "$_git_path/*" >.git/info/sparse-checkout
    git pull --quiet --depth 1 origin "$_git_ref" >&2 || \
      error "Unable to sparse-checkout. Check your Git ref ($git_ref) and path ($git_path)."
  else
    git fetch --quiet --tags origin >&2 || \
      error "Unable to fetch remote. Check your Git url."
    git checkout --quiet "$git_ref" >&2 || \
      error "Unable to checkout ref. Check your Git ref ($git_ref)."
  fi
  # shellcheck disable=SC2010,SC2012
  if [ "$(ls -A | grep -v '^.git$' -c)" = "0" ]; then
    error "No files have been checked out. Check your Git ref ($git_ref) and path ($git_path)."
  fi
}

# helm_v2()
helm_v2() {
  "$HELM_BIN" version -c --short | grep -q v2
}

# helm_check()
helm_check() {
  "$HELM_BIN" help | grep -qF "The Kubernetes package manager"
}

# helm_init(helm_home)
helm_init() {
  if ! helm_check; then return 1; fi
  if ! helm_v2; then return 0; fi
  _helm_home=$1
  "$HELM_BIN" init --client-only --stable-repo-url https://charts.helm.sh/stable --home "$_helm_home" >/dev/null
  HELM_HOME=$_helm_home
  export HELM_HOME
}

# helm_package(target_path, source_path, chart_name)
helm_package() {
  _target_path=$1
  _source_path=$2
  _chart_name=$3

  tmp_target="$(mktemp -d "$TMPDIR/helm-git.XXXXXX")"
  cp -r "$_source_path" "$tmp_target/$_chart_name"
  _source_path="$tmp_target/$_chart_name"
  cd "$_target_path" >&2

  package_args=$helm_args
  helm_v2 && package_args="$package_args --save=false"
  # shellcheck disable=SC2086
  "$HELM_BIN" package $package_args "$_source_path" >/dev/null
  ret=$?

  rm -rf "$tmp_target"

  # forward return code
  return $ret
}

# helm_dependency_update(target_path)
helm_dependency_update() {
  _target_path=$1

  # shellcheck disable=SC2086
  "$HELM_BIN" dependency update $helm_args "$_target_path" >/dev/null
}

# helm_index(target_path, base_url)
helm_index() {
  _target_path=$1
  _base_url=$2

  # shellcheck disable=SC2086
  "$HELM_BIN" repo index $helm_args --url="$_base_url" "$_target_path" >/dev/null
}

# helm_inspect_name(source_path)
helm_inspect_name() {
  _source_path=$1

  # shellcheck disable=SC2086
  output=$("$HELM_BIN" inspect chart $helm_args "$_source_path")
  name=$(echo "$output" | grep -e '^name: ' | cut -d' ' -f2)
  echo "$name"
  [ -n "$name" ]
}

# main(raw_uri)
main() {
  helm_args="" # "$1 $2 $3"
  _raw_uri=$4  # eg: git+https://git.com/user/repo@path/to/charts/index.yaml?ref=master

  # If defined, use $HELM_GIT_HELM_BIN as $HELM_BIN.
  if [ -n "$HELM_GIT_HELM_BIN" ]
  then
    export HELM_BIN="${HELM_GIT_HELM_BIN}"
  # If not, use $HELM_BIN after sanitizing it or default to 'helm'.
  elif
    [ -z "$HELM_BIN" ] ||
    # terraform-provider-helm: https://github.com/aslafy-z/helm-git/issues/101
    echo "$HELM_BIN" | grep -q "terraform-provider-helm" ||
    # helm-diff plugin: https://github.com/aslafy-z/helm-git/issues/107
    echo "$HELM_BIN" | grep -q "diff"
  then
    export HELM_BIN="helm"
  fi

  if ! helm_check; then
    error "'$HELM_BIN' is not a valid helm binary path."
  fi

  # Parse URI

  string_starts "$_raw_uri" "$url_prefix" ||
    error "Invalid format, got '$_raw_uri'. $error_invalid_prefix"

  _raw_uri=$(echo "$_raw_uri" | sed 's/^git+//')

  git_proto=$(echo "$_raw_uri" | cut -d':' -f1)
  readonly git_proto="$git_proto"
  string_contains "$allowed_protocols" "$git_proto" ||
    error "$error_invalid_protocol"

  git_repo=$(echo "$_raw_uri" | sed -E 's#^([^/]+//[^/]+[^@\?]+)@?[^@\?]+\??.*$#\1#')
  readonly git_repo="$git_repo"
  # TODO: Validate git_repo
  git_path=$(echo "$_raw_uri" | sed -E 's#.*@([^\?]+)\/([^\?]+).*(\?.*)?#\1#')
  readonly git_path="$git_path"
  # TODO: Validate git_path
  helm_file=$(echo "$_raw_uri" | sed -E 's#.*@([^\?]+)\/([^\?]+).*(\?.*)?#\2#')
  readonly helm_file="$helm_file"

  git_ref=$(echo "$_raw_uri" | sed '/^.*ref=\([^&#]*\).*$/!d;s//\1/')
  # TODO: Validate git_ref
  if [ -z "$git_ref" ]; then
    warning "git_ref is empty, defaulted to 'master'. Prefer to pin GIT ref in URI."
    git_ref="master"
  fi
  readonly git_ref="$git_ref"

  git_sparse=$(echo "$_raw_uri" | sed '/^.*sparse=\([^&#]*\).*$/!d;s//\1/')
  [ -z "$git_sparse" ] && git_sparse=1

  helm_depupdate=$(echo "$_raw_uri" | sed '/^.*depupdate=\([^&#]*\).*$/!d;s//\1/')
  [ -z "$helm_depupdate" ] && helm_depupdate=1

  helm_package=$(echo "$_raw_uri" | sed '/^.*package=\([^&#]*\).*$/!d;s//\1/')
  [ -z "$helm_package" ] && helm_package=1

  debug "repo: $git_repo ref: $git_ref path: $git_path file: $helm_file sparse: $git_sparse depupdate: $helm_depupdate package: $helm_package"
  readonly helm_repo_uri="git+$git_repo@$git_path?ref=$git_ref&sparse=$git_sparse&depupdate=$helm_depupdate&package=$helm_package"
  debug "helm_repo_uri: $helm_repo_uri"

  # Setup cleanup trap
  cleanup() {
    rm -rf "$git_root_path" \
      "$helm_home_target_path" \
      "$helm_target_path"
  }
  trap cleanup EXIT

  git_root_path="$(mktemp -d "$TMPDIR/helm-git.XXXXXX")"
  readonly git_root_path="$git_root_path"
  git_sub_path=$(path_join "$git_root_path" "$git_path")
  readonly git_sub_path="$git_sub_path"
  git_checkout "$git_sparse" "$git_root_path" "$git_repo" "$git_ref" "$git_path" ||
    error "Error while git_sparse_checkout"

  case "$helm_file" in
  index.yaml) ;;
  *.tgz) ;;
  *)
    # value files
    cat "$git_path/$helm_file"
    return
    ;;
  esac

  helm_target_path="$(mktemp -d "$TMPDIR/helm-git.XXXXXX")"
  readonly helm_target_path="$helm_target_path"
  helm_target_file="$(path_join "$helm_target_path" "$helm_file")"
  readonly helm_target_file="$helm_target_file"

  # Set helm home
  if helm_v2; then
    debug "helm2 detected. initializing helm home"
    helm_home=$("$HELM_BIN" home)
    if [ -z "$helm_home" ]; then
      helm_home_target_path="$(mktemp -d "$TMPDIR/helm-git.XXXXXX")"
      readonly helm_home_target_path=$helm_home_target_path
      helm_init "$helm_home_target_path" || error "Couldn't init helm"
      helm_home="$helm_home_target_path"
    fi
    helm_args="$helm_args --home=$helm_home"
  fi

  chart_search_root="$git_sub_path"

  chart_search=$(find "$chart_search_root" -maxdepth 2 -name "Chart.yaml" -print)
  chart_search_count=$(echo "$chart_search" | wc -l)

  echo "$chart_search" | {
    while IFS='' read -r chart_yaml_file; do
      chart_path=$(dirname "$chart_yaml_file")
      chart_name=$(helm_inspect_name "$chart_path")

      if [ "$helm_depupdate" = "1" ]; then
        helm_dependency_update "$chart_path" ||
          error "Error while helm_dependency_update"
      fi
      if [ "$helm_package" = "1" ]; then
      helm_package "$helm_target_path" "$chart_path" "$chart_name" ||
        error "Error while helm_package"
      fi
    done
  }

  [ "$chart_search_count" -eq "0" ] &&
    error "No charts have been found"

  helm_index "$helm_target_path" "$helm_repo_uri" ||
    error "Error while helm_index"

  debug "helm index produced at $helm_target_file: $(cat "$helm_target_file")"
  cat "$helm_target_file"
}
