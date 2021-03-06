#!/bin/bash
#### ENV VARS NEEDED BY THIS SCRIPT
# BRANCH            - The current ready branch (set by TeamCity)
# REPO              - The Repo on Github (set by TeamCity)
# SLACK_TOKEN       - For posting to slack
# SLACK_CHANNEL_ID  - For posting to slack
# BUILD_URL         - URL to the build on TeamCity, so we can link in slack messages
# COMMIT_URL        - URL to the commit on GitHub. This script will add the commit SHA

################################################
# retry
###############################################
function retry()
{
    local n=0
    local try=$1
    local cmd="${*: 2}"
    [[ $# -le 1 ]] && {
    echo "Usage $0 <retry_number> <Command>"; }

    until [[ $n -ge $try ]]
    do
        # shellcheck disable=SC2015
        ($cmd) && return 0 || {
            echo "Command failed: $cmd"
            ((n++))
            echo "Will retry in $n seconds..."
            sleep $n;
            echo "Retry #$n ..."
            }

    done
    return 1
}

################################################
# Install dependencies
###############################################
teamcityinstall(){
	step_start "Installing dependencies"
	teamcityinstallscript=$(node -e "console.log(require('./package.json').scripts['teamcity-install'] || '')")
	if [ "$teamcityinstallscript" = '' ]
	then
		echo "No npm teamcity-install script available"
	else
		add_npm_token || _exit $? "Adding NPM_TOKEN env var to .npmrc failed"
		npm run teamcity-install || _exit $? "npm run teamcity-install failed"
		remove_npm_token || _exit $? "Removing NPM_TOKEN env var from .npmrc failed"
	fi
}

################################################
# Code formatting
###############################################
format(){
	step_start "Formatting code"
	formatscript=$(node -e "console.log(require('./package.json').scripts.format || '')")
	if [ "$formatscript" = '' ]
	then
		echo "No npm run format script available"
	else
		npm run format || _exit $? "npm run format failed"
		(git add . && git commit -m "format code" --author "${lastCommitAuthor}") || echo "Ignoring: Could not git add changes after formatting, maybe no changes"
	fi
}

################################################
# Package Update
###############################################
package_update(){
	case ${BRANCH} in
	*_package_update)
		add_npm_token || _exit $? "Adding NPM_TOKEN env var to .npmrc failed"
		echo "Doing npm install because we are running a package update ready branch"
		rm -f package-lock.json || _exit $? "could not remove package-lock.json (_package_update)"
		rm -rf node_modules || _exit $? "could not remove node_modules (_package_update)"
		(retry 2 npm install --package-lock-only) || _exit $? "npm install failed (_package_update)"
		(retry 4 npm audit fix --package-lock-only) || _exit $? "npm audit fix failed (_package_update)"
		(git add package-lock.json && git commit -m "update package-lock.json" --author "${lastCommitAuthor}") || echo "Ignoring: Could not git add package-lock.json, maybe no changes"
		nodeVersion=$(node -e "console.log(require('./package.json').engines.node || '')")
		if [ "$nodeVersion" = '' ]
		then
			echo "No node version in package.json"
		else
			echo "Writing node version ${nodeVersion} to .nvmrc"
			echo "${nodeVersion}" > .nvmrc || _exit $? "Could not write node version to .nvmrc (_package_update)"
			(git add .nvmrc && git commit -m "update .nvmrc to ${nodeVersion}" --author "${lastCommitAuthor}") || echo "Ignoring: Could not git add .nvmrc, maybe no changes"
		fi
		remove_npm_token || _exit $? "Removing NPM_TOKEN env var from .npmrc failed"
		;;
	esac
}

################################################
# Build
###############################################
build(){
	step_start "Building"
	buildscript=$(node -e "console.log(require('./package.json').scripts.build || '')")
	if [ "$buildscript" = '' ]
	then
		echo "No npm run build script available"
	else
		add_npm_token || _exit $? "Adding NPM_TOKEN env var to .npmrc failed"
		npm run build || _exit $? "npm run build failed"
		remove_npm_token || _exit $? "Removing NPM_TOKEN env var from .npmrc failed"
	fi
}

add_npm_token(){
	if [ -n "$NPM_TOKEN" ]; then
		if [ -f .npmrc ]; then
			mv .npmrc .npmrc-backup
		fi
		# shellcheck disable=SC2016
		if [ -f .npmrc ]; then
			echo '//registry.npmjs.org/:_authToken=${NPM_TOKEN}' | cat - .npmrc-backup >  .npmrc
		else
			echo '//registry.npmjs.org/:_authToken=${NPM_TOKEN}' > .npmrc
		fi

		# if it is a monorepo, add the .npmrc to each subdir
		if [ -d packages ];
			then for subdir in packages/*; do
				cp .npmrc "$subdir"/.npmrc
			done
		fi
	fi
}

remove_npm_token(){
	if [ -n "$NPM_TOKEN" ]; then
		rm .npmrc
		if [ -f .npmrc-backup ]; then
    		mv .npmrc-backup .npmrc
		fi

		# if it is a monorepo, remove the .npmrc from each subdir
		if [ -d packages ];
			then for subdir in packages/*; do
				rm "$subdir"/.npmrc
			done
		fi
	fi
}

################################################
# Deploy to production
###############################################
deploy(){
	step_start "Deploying to production"
	commitMessage=$(git log -1 --pretty=%B)
	lastCommitAuthor=$(git log --pretty=format:'%an' -n 1)
	deployscript=$(node -e "console.log(require('./package.json').scripts.deploy || '')")
	if [ "$deployscript" = '' ]
	then
		_exit 0 "No npm run deploy script available"
	else
		node -e "if((require('./package.json').scripts.deploy || '').indexOf('git@heroku.com/${REPO}.git')===-1 && '${REPO}' !== 'vaccination' && '${REPO}' !== 'email-generator' && '${REPO}' !== 'practio-type-1-booking') process.exit(1)" || _exit $? "npm run deploy does not push to ${REPO} on Heroku"
		(retry 2 npm run deploy) || _exit $? "npm run deploy failed"
	fi
	slack "Success deploying ${slackProject} ${slackUser} ${pullRequestLink}
${commitMessage} - <${COMMIT_URL}${mergeCommitSha}|view commit> - <${BUILD_URL}|view build log>" green

	################################################
	# Add git tag and push to GitHub
	################################################

	step_start "Adding git tag and pushing to GitHub"
	git config user.email "build@practio.com" || _exit $? "Could not set git user.email"
	git config user.name "Teamcity" || _exit $? "Could not set git user.name"
	datetime=$(date +%Y-%m-%d_%H-%M-%S)
	git tag -a "${project}.production.${datetime}" -m "${commitMessage}" || _exit $? "Could not create git tag"
	(retry 2 git push origin --tags) || _exit $? "Could not push git tag to GitHub"
}

################################################
# Delete Ready branch
# Always last thing done after merge (fail or success)
################################################
build_done (){
	step_start "Deleting ready branch on github"
	(retry 2 git push origin ":ready/${BRANCH}")
	step_start "Post to slack"
	if [ "$1" = '0' ]
	then
		if [ "$2" != '' ]
		then
			slack "Warning merging: $2 ${slackProject} ${slackUser} ${pullRequestLink}
${commitMessage} - <${BUILD_URL}|view build log> " yellow
			message="$2
${project} ${slackUser}
${BUILD_URL}
${commitMessage}"
		else
			slack "Success merging: ${slackProject} ${slackUser} ${pullRequestLink}
${commitMessage} - <${COMMIT_URL}${mergeCommitSha}|view commit> - <${BUILD_URL}|view build log>" green
			message="Success merging ${project}
${slackUser}
${COMMIT_URL}${mergeCommitSha}
${commitMessage}"
			deploy
			_exit 0
		fi
	else
		slack "Failure merging: $2 ${slackProject}> ${slackUser} ${pullRequestLink}
${commitMessage} - <${BUILD_URL}|view build log> " red "$3"
		message="Failure merging: $2
${project} ${slackUser}
${BUILD_URL}
${commitMessage}
$3"
	fi
	step_end
	echo "
${message}"
	exit "$1"
}

_exit (){
	step_end
	if [ "$1" = '0' ]
	then
		exit
	else
		slack "Failure: $2 ${slackProject} ${slackUser}
${commitMessage} - <${BUILD_URL}|view build log> " red
		exit "$1"
	fi
}

################################################
# TeamCity step helper functions
################################################
stepName=""
step_end(){
	echo "##teamcity[blockClosed name='${stepName}']"
}
step_start(){
	if [ "${stepName}" != '' ]
	then
		step_end
	fi
	stepName=$(echo "-- $1 --")
	echo "##teamcity[blockOpened name='${stepName}']"
}

################################################
# Posting messages to slack
################################################
slack(){
	if [ "$2" = 'green' ]
	then
		symbol="✅"
	elif [ "$2" = 'yellow' ]
	then
		symbol="❗"
	elif [ "$2" = 'red' ]
	then
		symbol="❌"
	fi
	curl -sS -X POST \
		"https://slack.com/api/chat.postMessage?token=${SLACK_TOKEN}&channel=${SLACK_CHANNEL_ID}" \
		--data-urlencode "text=$symbol $1" \
		-s > /dev/null
	if [ "$3" != '' ]
	then
		step_start "Post error log to slack"
		curl -sS -X POST "https://slack.com/api/files.upload?token=${SLACK_TOKEN}&filetype=text&filename=${githubProject}.txt&channels=${SLACK_CHANNEL_ID}" -s \
			-F content="$3"
	fi
}

### After teamcity script
after_teamcity_script(){
  code="$1"
  err=$(node -e "
  const fs = require('fs');
  const path = require('path');
  let log = fs.readFileSync(path.join(__dirname, 'err.log'), 'utf-8')
    .split('\\n')
    .filter(line => !/^npm (ERR|WARN)/.test(line))
    .join('\\n')
    .replace(/\\|n/g, '\\n');
  console.log(log);
  " && rm -f err.log)

  if [ "${code}" != 0 ]
  then
    build_done "${code}" "Failing test(s)"	"${err}"
  fi
}



################################################
### START OF SCRIPT - HERE WE GO!
################################################
#npmpath=$(which npm)
#alias npm="node --max_old_space_size=8000 ${npmpath}"

if [ "$BRANCH" = 'refs/heads/master' ]
then
	echo "master branch, doing nothing"
	exit 0
fi

pullRequestLink=""
project=$(node -e "console.log(require('./package.json').name || '')")
githubRemote=$(git remote -v | grep origin | grep fetch | grep github)
githubProject=$(node -e "console.log('$githubRemote'.split(':').pop().split('.').shift())")
slackProject="<https://github.com/${githubProject}|${project}>"
slackUser=$(curl -sS -L 'https://raw.githubusercontent.com/practio/ci-merge/master/getSlackUser.sh' | bash)
commitMessage="${BRANCH}"
git config user.email "build@practio.com" || build_done $? "Could not set git email"
git config user.name "Teamcity" || build_done $? "Could not set git user name"

step_start "Finding author"

lastCommitAuthor=$(git log --pretty=format:'%an' -n 1)

echo "This will be the author of the merge commit in master: ${lastCommitAuthor} (the last commit in branch was done by this person)"


case ${BRANCH} in
*_package_update)
	## If the ready branch ends with "_package_update" we will not try to match to a pull request.
	step_start "No pull request"
	pullRequestNumber="none"
	pullRequestLink=""
	;;
*)

	################################################
	# Make sure git fetches (hidden) Pull Requests
	# by adding:
	# fetch = +refs/pull/*/head:refs/remotes/origin/pullrequest/*
	# to .git/config under the origin remote
	################################################

	step_start "Ensuring fetch of pull requests to .git/config"

	currentFetch=$(grep '	fetch =.\+refs/pull/\*/head:refs/remotes/origin/pullrequest/\*' .git/config)
	if [ "$currentFetch" = '' ]
	then
		# Avoid -i flag for sed, because of platform differences
		sed 's/\[remote \"origin\"\]/[remote "origin"]'\
'	fetch = +refs\/pull\/*\/head:refs\/remotes\/origin\/pullrequest\/*/g' .git/config >.git/config_with_pull_request || build_done $? "Could not sed .git/config"
		cp .git/config .git/config.backup || build_done $? "Could not copy .git/config"
		mv .git/config_with_pull_request .git/config || build_done $? "Could not mv .git/config"
		echo 'Added fetch of pull request to .git/config:'
		cat .git/config
	else
		echo 'Fetch of pull request already in place in .git/config'
	fi
	(retry 2 git fetch --prune) || build_done $? "Could not git fetch"

	########################################################################################
	# Lookup PR number
	# By looking the SHA checksum of the current branchs latests commit
	# And finding a pull request that has a matching SHA checksum as the lastest commit
	# This enforces a restriction that you can only merge branches that match a pull request
	# And using the number of the pull request later, we can close the pull request
	# by making the squash merge commit message include "fixes #[pull request number] ..."
	########################################################################################

	step_start "Finding pull request that matches current branch"

	currentSha=$(git log -1 --format="%H")
	echo "Current SHA:"
	echo "${currentSha}"


	error='
	Did you try to deploy a branch that is not a pull request?
	Or did you forget to push your changes to github?'

	matchingPullRequest=$(git show-ref | grep "$currentSha" | grep 'refs/remotes/origin/pullrequest/')
	if [ "$matchingPullRequest" = '' ] ; then
		echo "Error finding matching pull request: ${error}" >&2; build_done 1 "Could not find matching pull request"
	fi
	echo "Matching pull request:"
	echo "${matchingPullRequest}"

	pullRequestNumber=$(echo "${matchingPullRequest}" | sed 's/[0-9a-z]* refs\/remotes\/origin\/pullrequest\///g' | sed 's/\s//g')
	echo "Extracted pull request number:"
	echo "${pullRequestNumber}"
	case ${pullRequestNumber} in
		''|*[!0-9]*) echo "Error pull request number does not match number regExp (weird!): ${error}" >&2; build_done 1 "Could not find pull request number";;
		*) echo "Success. Pull request number passes regExp test for number. Exporting pullRequestNumber=${pullRequestNumber}" ;;
	esac
	pullRequestLink="<https://github.com/practio/${project}/pull/${pullRequestNumber}|PR#${pullRequestNumber}>"
	;;
esac

#####################################################################
# Checkout master
# Cleanup any leftovers for previous failed merges (reset --hard, clean -fx)
# And pull master
#####################################################################

step_start "Checking out master, resetting (hard), pulling from origin and cleaning"

(retry 2 git fetch --prune) || build_done $? "Could not git fetch"
git checkout master || build_done $? "Could not checkout master. Try to merge master into your Pull Request-branch and solve any merge conflicts"
git branch --set-upstream-to=origin/master master || build_done $? "Could not set upstream for master to origin/master"
git reset --hard origin/master || build_done $? "Could not reset to master"
(retry 2 git pull) || build_done $? "Could not pull master"
git clean -fx || build_done $? "Could not git clean on master"


################################################
# Merge into master
# You will want to use you own email here
################################################

step_start "Merging ready branch into master, with commit message that closes pull request number ${pullRequestNumber}"

message_on_commit_error(){
	commitErrorCode=$1
	echo "Commiting changes returned an error (status: ${commitErrorCode}). We are assuming that this is due to no changes, and exiting gracefully"
	build_done 0 "No changes in ready build"
}

git merge --squash "ready/${BRANCH}" || build_done $? "Merge conflicts (could not merge)"
branchWithUnderscore2SpacesAndRemovedTimestamp=$(echo "${BRANCH}" | sed -e 's/_/ /g' | sed -e 's/\/[0-9]*s$//g')
if [ "$pullRequestNumber" = 'none' ]
then
	commitMessage="${branchWithUnderscore2SpacesAndRemovedTimestamp}"
else
	commitMessage="fixes #${pullRequestNumber} - ${branchWithUnderscore2SpacesAndRemovedTimestamp}"
fi
echo "Committing squashed merge with message: \"${message}\""
git commit -m "${commitMessage}" --author "${lastCommitAuthor}" || message_on_commit_error $?


mergeCommitSha=$(git log -1 --format="%H")


################################################
# Check node.js version
################################################
nodeSpecified=$(node -e "console.log(require('./package.json').engines.node || '')")
nodeCurrent=$(node --version | sed -e 's/v//g')
if [ "${nodeSpecified}" != "${nodeCurrent}" ]
then
	step_start "Changing node.js v${nodeCurrent}->v${nodeSpecified}"
	sudo npm install -g n || build_done 1 "Could not install n module to change node version from ${nodeCurrent} to ${nodeSpecified}"
	sudo n "${nodeSpecified}" || build_done 1 "n module failed to change node version from ${nodeCurrent} to ${nodeSpecified}"
	echo "Running node.js:"
	node --version
fi

################################################
# Check npm version
################################################
npmSpecified=$(node -e "console.log(require('./package.json').engines.npm || '')")
npmCurrent=$(npm --version)
if [ "${npmSpecified}" != "${npmCurrent}" ]
then
	step_start "Changing npm v${npmCurrent}->v${npmSpecified}"
	sudo npm install -g "npm@${npmSpecified}" || build_done 1 "Could not install npm version ${npmSpecified}. Changing from current npm version ${npmCurrent}"
fi

################################################
# Package update (If it is a *_package_update branch)
################################################

package_update

################################################
# Install dependencies
################################################

teamcityinstall

################################################
# Build
################################################

build

################################################
# Format code
################################################

format

################################################
# Run tests, and capture output to stderr
################################################

step_start "Running tests with >npm run teamcity "

teamcityscript=$(node -e "console.log(require('./package.json').scripts.teamcity || '')")
if [ "$teamcityscript" = '' ]
then
	build_done 1 "No 'teamcity' script in package.json"
fi

## file descriptor 5 is stdout
exec 5>&1
## redirect stderr to stdout for capture by tee, and redirect stdout to file descriptor 5 for output on stdout (with no capture by tee)
## after capture of stderr on stdout by tee, redirect back to stderr
npm run teamcity 2>&1 1>&5 | tee err.log 1>&2
exit_code=${PIPESTATUS[0]}

## Executes e2e tests
## In the end the server process gets killed
## which causes this main process to die too
## To avoid that, we run e2e tests in a different process
## and wait for it to finish
teamcity_e2e_script=$(node -e "console.log(require('./package.json').scripts['teamcity:e2e'] || '')")
if [ "$exit_code" == "0" ] && [ "$teamcity_e2e_script" != '' ]
then
  npm run teamcity:e2e &
  proc=$!
  wait $proc
  exit_code=${PIPESTATUS[0]}
fi

after_teamcity_script "$exit_code"


################################################
# Push changes to github
################################################

step_start "Pushing changes to github master branch"

(retry 2 git push origin master) || build_done $? "Could not push changes to GitHub"

build_done 0
