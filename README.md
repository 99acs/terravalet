# Terravalet

A tool to help with some [Terraform](https://www.terraform.io/) operations.

1. It can generate migration scripts that work also for Terraform workspaces.
2. It can generate import and remove states script for existing resources.

The idea of migrations comes from [tfmigrate](https://github.com/minamijoyo/tfmigrate). Then this blog [post](https://medium.com/@lynnlin827/moving-terraform-resources-states-from-one-remote-state-to-another-c76f8b76a996)  made me realize that `terraform state mv` had a bug and how to workaround it.

**DISCLAIMER Manipulating Terraform state is inherently dangerous. It is your responsibility to be careful and ensure you UNDERSTAND what you are doing**.

## Status

This is BETA code, although we already use it in production.

The project follows [semantic versioning](https://semver.org/). In particular, we are currently at major version 0: anything MAY change at any time. The public API SHOULD NOT be considered stable.

## Overall approach and migration scripts

The overall approach is for Terravalet to generate migration scripts, not to perform any changes directly. This for two reasons:

1. Safety. The operator can review the generated migration scripts for correctness.
2. Gitops-style. The migration scripts are meant to be stored in git in the same branch (and thus same PR) that performs the Terraform changes and can optionally be hooked to an automatic deployment system.

Terravalet takes as input the output of `terraform plan` per each involved root module and generates one UP and one DOWN migration script.

### Remote and local state

At least until Terraform 0.14, `terraform state mv` has a bug: if a remote backend for the state is configured (which will always be the case for prod), it will remove entries from the remote state but it will not add entries to it. It will fail silently and leave an empty backup file, so you loose your state.

For this reason Terravalet operates on local state and leaves to the operator to perform `terraform state pull` and `terraform state push`.

### Terraform workspaces

Be careful when using Terraform workspaces, since they are invisible and persistent global state :-(. Remember to always explicitly run `terraform workspace select` before anything else.

## Usage

There are three modes of operation:
- [Rename resources](#rename-resources-within-the-same-state) within the same state, with optional fuzzy match.
- [Move resources](#-move-resources-from-one-state-to-another) from one state to another.
- [Import existing resources](#-import-existing-resources) for Terraform out-of-band resouces.

they will be explained in the following sections.

You can also look at the tests and in particular at the files below testdata/ for a rough idea.

## Rename resources within the same state

Only one Terraform root module (and thus only one state) is involved. This actually covers two different use cases:

1. Renaming resources within the same root module.
2. Moving resources to/from a non-root Terraform module (this will actually _rename_ the resources, since they will get or loose the `module.` prefix).

### Collect information and remote state

```
$ cd $ROOT_MODULE_DIR
$ terraform workspace select $WS
$ terraform plan -no-color 2>&1 | tee plan.txt

$ terraform state pull > local.tfstate
$ cp local.tfstate local.tfstate.BACK
```

The backup is needed to recover in case of errors. It must be done now.

### Generate migration scripts: exact match, success

Take as input the Terraform plan `plan.txt` (explicit) and the local state `local.tfstate` (implicit) and generate UP and DOWN migration scripts:

```
$ terravalet rename \
    -plan plan.txt -up 001_TITLE.up.sh -down 001_TITLE.down.sh
```

### Generate migration scripts: exact match, failure

Depending on _how_ the elements have been renamed in the Terraform configuration, it is possible that the exact match will fail:

```
$ terravalet rename \
    -plan plan.txt -up 001_TITLE.up.sh -down 001_TITLE.down.sh
match_exact:
unmatched create:
  aws_route53_record.private["foo"]
unmatched destroy:
  aws_route53_record.foo_private
```

In this case, you can attempt fuzzy matching.

### Generate migration scripts: fuzzy match

**WARNING** Fuzzy match can make mistakes. It is up to you to validate that the migration makes sense.

If the exact match failed, it is possible to enable [q-gram distance](https://github.com/dexyk/stringosim) fuzzy matching with the `-fuzzy-match` flag:

```
$ terravalet rename-fuzzy-match \
    -plan plan.txt -up 001_TITLE.up.sh -down 001_TITLE.down.sh
WARNING fuzzy match enabled. Double-check the following matches:
 9 aws_route53_record.foo_private -> aws_route53_record.private["foo"]
```

### Run the migration script

1. Review the contents of `001_TITLE.up.sh`.
2. Run it: `sh ./001_TITLE.up.sh`

### Push the migrated state

1. `terraform state push local.tfstate`. In case of error, DO NOT FORCE the push unless you understand very well what you are doing.

### Recovery in case of error

Push the `local.tfstate.BACK`.

## Move resources from one state to another

Two Terraform root modules (and thus two states) are involved. The names of the resources stay the same, but we move them from the `$SRC_ROOT` root module to the `$DST_ROOT` root module.

### Collect information and remote state

Source root:

```
$ cd $SRC_ROOT
$ terraform workspace select $WS
$ terraform plan -no-color 2>&1 | tee src-plan.txt

$ terraform state pull > local.tfstate
$ cp local.tfstate local.tfstate.BACK
```

Destination root:

```
$ cd $DST_ROOT
$ terraform workspace select $WS
$ terraform plan -no-color 2>&1 | tee dst-plan.txt

$ terraform state pull > local.tfstate
$ cp local.tfstate local.tfstate.BACK
```

The backups are needed to recover in case of errors. They must be done now.

### Generate migration scripts

Take as input the two Terraform plans `src-plan.txt`, `dst-plan.txt`, the two local state files in the corresponding directories and generate UP and DOWN migration scripts.

Assuming the following directory layout, where `repo` is the top-level directory and `src` and `dst` are the two Terraform root modules:

```
repo/
├── src/
├── dst/
```

the generated migration scripts will be easier to understand and portable from one operator to another if you run terravalet from the `repo` directory and use relative paths:

```
$ cd repo
$ terravalet move \
    -src-plan  src/src-plan.txt  -dst-plan  dst/dst-plan.txt \
    -src-state src/local.tfstate -dst-state dst/local.tfstate \
    -up 001_TITLE.up.sh -down 001_TITLE.down.sh
```

### Run the migration script

1. Review the contents of `001_TITLE.up.sh`.
2. Run it: `sh ./001_TITLE.up.sh`

### Push the migrated states

In case of error, DO NOT FORCE the push unless you understand very well what you are doing.

```
$ cd src
$ terraform state push local.tfstate
```

and

```
$ cd dst
$ terraform state push local.tfstate
```

### Recovery in case of error

Push the two backups `src/local.tfstate.BACK` and `dst/local.tfstate.BACK`.

## Import existing resources

The scope is to import as much as possible existing out-of-band resources into terraform state. We want to avoid to create something that already exists. The example used in this section refers to the github provider. Suppose you have new already created resources added to `.tf` configuration.

### Generate a plan in json format

terraform plan:

```
$ cd $SRC_ROOT
$ terraform plan -no-color 2>&1 -out src-plan
$ terraform show -json my_plan | tee src-plan.json

```

### Generate import/remove scripts

Take as input the Terraform plan in json format `src-plan.json` and generate UP and DOWN import scripts.

```
$ cd repo
$ terravalet import \
    -res-defs  my_definitions.json
    -src-plan  src/src-plan.json \
    -up import.up.sh -down import.down.sh
```

`import.up.sh ` will be generated with all the `import` flags following the plan containing `create` action.
`import.down.sh ` will be generated with all the `state rm` flags as a mirror of import above.

### Run the import script

1. Review the contents of `import.up.sh `.
   * Ensure the parents resources are placed on the top of `up` script followed by their children.
   * Ensure the children resources are placed on the top of `down` script followed by their parents.
   * Ensure the correctness of parameters. 
2. Run it: `sh ./import.up.sh`

**1. NOTE: even if terravalet tries to guess the correct order of this action, ensure the script import first the root resource**

**2. NOTE: The script modifies the remote state, but it is not dangerous because it only import new resources if they already exist and it doesn't create/destroy anything.**

Terraform will try to import as much as possible, if the corresponding address in state doesn't exist yet, it means it should be created later using `terraform apply`, actually the resource is in `.tf` configuration, but not yet in real world.

#### Example

Here is a new plan, scripts have been already generated:

```
 $ terraform plan
 .....
 Plan: 6 to add, 0 to change, 0 to destroy.
```
These are new resources, let's run the import script and run the plan again:

```
$ sh import.up.sh
module.github.github_repository.repos["test-import-gh"]: Importing from ID "test-import-gh"...
module.github.github_repository.repos["test-import-gh"]: Import prepared!
  Prepared github_repository for import
module.github.github_repository.repos["test-import-gh"]: Refreshing state... [id=test-import-gh]

Import successful!
.....
```

During the run an error like this can raise:

```
Error: Cannot import non-existent remote object

While attempting to import an existing object to
github_team_repository.all_teams["test-import-gh.integration"], the provider
detected that no object exists with the given id. Only pre-existing objects
can be imported; check that the id is correct and that it is associated with
the provider's configured region or endpoint, or use "terraform apply" to
create a new remote object for this resource.
```

In this specific case the out-of-band resource didn't have a setting yet about teams, so it's normal.

Next plan should be different:

```
$ terraform plan
.....
Plan: 3 to add, 2 to change, 0 to destroy.
```

In conclusion, the plan now is close to real resources states and terraform is now aware of them.
In every case plan doesn't contain any `destroy` sentence.

### Rollback

Run `import.down.sh` script that remove the same resources from terraform state that have been imported with `import.up.sh`.

### Resources definition

Terravalet doesn't know anything about resources, it just parses the plan and uses the resources configuration file passed via the flag `res-defs`. An example can be found in [testdata](testdata/terravalet_imports_definitions.json) containing some github resources as example. 

Basically we need to inform Terravalet where to search data to build the up/down scripts. The correct information can be found on the [specific provider documentation](https://registry.terraform.io/browse/providers). Under the hood, Terravalet matches the parsed plan and resources definition file. 

1. The json resources definition is a map of resources type objects identified by their own name as a key.
2. The resource type object may have or not `priority`: import statement for that resource must be placed at the top of up.sh and at the bottom of down.sh (resources that must be imported before others).
3. The resource type object may have or not `separator`: in case of multiple arguments it is mandatory and it will be used to join them. Using the example below, `tag, owner` will be joined into the string `<tag_value>:<owner_value>`.
4. The resource type object must have `variables`: a list of fields names that are the keys in the plan to retreive the correct values building the import statement. Using the example below, terravalet will search for a keys `tag` and `owner` in terraform plan for that resource. 

```
{
  "dummy_resource1": {
    "priority": 1,
    "separator": ":"
    "variables": [
      "tag",
      "owner"
    ]
  }
}
```

### Error cases

Ignorable errors:
1. Resource X doesn't exists yet, it resides only in new terraform configuration.
2. Resource X exists, but depends on resource Y that has not been imported yet (should be fine setting the priority)

NOT ignorable errors: 
1. Provider specific argument ID is wrong

## Install

### Install from binary package

1. Download the archive for your platform from the [releases page](https://github.com/Pix4D/terravalet/releases).
2. Unarchive and copy the `terravalet` executable somewhere in your `$PATH`.

### Install from source

1. Install [Go](https://golang.org/).
2. Install [task](https://taskfile.dev/).
3. Run `task`
   ```
   $ task
   ```
4. Copy the executable `bin/terravalet` to a directory in your `$PATH`.

## Making a release

### Setup

1. Install [github-release](https://github.com/github-release/github-release).
2. Install [gopass](https://github.com/gopasspw/gopass) or equivalent.
3. Configure a GitHub token:
    * Go to [Personal Access tokens](https://github.com/settings/tokens)
    * Click on "Generate new token"
    * Select only the `repo` scope
4. Store the token securely with a tool like `gopass`. The name `GITHUB_TOKEN` is expected by `github-release`
   ```
   $ gopass insert gh/terravalet/GITHUB_TOKEN
   ```

### Each time

1. Update [CHANGELOG](CHANGELOG.md)
2. Update this README and/or additional documentation.
3. Commit and push.
4. Begin the release process with
   ```
   $ env RELEASE_TAG=v0.1.0 gopass env gh/terravalet task release
   ```
5. Finish the release process by following the instructions printed by `task` above.
6. To recover from a half-baked release, see the hints in the [Taskfile](Taskfile.yml).

## License

This code is released under the MIT license, see file [LICENSE](LICENSE).
