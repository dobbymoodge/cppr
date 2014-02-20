Tool for creating pull requests against one or more branches of a repo from a list of commits or from an existing pull request URL

# Testing #

    git clone git@github.com:dobbymoodge/cppr.git
    cd cppr
    . ./testenv.sh
    cd /path/to/repo
    git cppr --target_branch b1 --target_branch b2 --my_remote origin --our_remote upstream --prefix parallel_pr_test commits...
