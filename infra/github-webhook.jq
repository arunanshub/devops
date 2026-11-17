# Request body for POST /repos/{owner}/{repo}/hooks, used by
# `just github-argocd-webhook`. The secret arrives on stdin (jq -R `input`) so
# it is never on a command line or in shell history; the URL arrives as $url.
# Only push events: Argo CD refreshes on push and ignores everything else.
# https://docs.github.com/en/rest/repos/webhooks#create-a-repository-webhook
{
  name: "web",
  active: true,
  events: ["push"],
  config: {
    url: $url,
    content_type: "json",
    insecure_ssl: "0",
    secret: input
  }
}
