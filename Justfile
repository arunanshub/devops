apply:
    sops exec-env --pristine 'tofu apply'

plan:
    sops exec-env --pristine 'tofu plan'
