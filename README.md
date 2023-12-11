# ybdb-vanguard

## Pre-requisites
- github.com account
- gitpod.io account
- git cli (https://github.com/git-guides/install-git)

## Setup
- Fork this repo
- Run `git clone https://github.com/[REPLACE_REPO_NAME]/ybdb-vanguard.git` to clone the forked repo to the local workstation
- Run `cd ybdb-vanguard` to change the directory to the cloned repo

## Getting Started with Gitpod:
[![Open in Gitpod](https://gitpod.io/button/open-in-gitpod.svg)](https://gitpod.io/from-referrer/)

## Into the distributed and postgres++ sql universe
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
</div>

[distributed sql:](init-dsql/README.md)
This will help you get started with yugabyte db and explore the distributed sql universe.

```bash
./run.sh
```

<details>

```bash
Select an exercise:
1. Into the distributed and postgres++ sql universe
2. Query tuning tips and tricks
3. Development innerloop workflow
4. Java microservices
5. Java testcontainers
6. Securing Spring Boot Microservices
7. Data migration workflow from mysql to ybdb
8. Change data capture(CDC) workflow from ybdb to postgres
9. Change data capture(CDC) streaming workflow from ysql to ycql
10. Data distribution and scalability
11. Data replication, fault tolerance and high availability
Enter the number of the exercise (0 to exit): 1
Initializing the workspace for Into the distributed and postgres++ sql universe.
[main 5e2b86a] Into the distributed and postgres++ sql universe
 1 file changed, 5 insertions(+), 38 deletions(-)
Enumerating objects: 5, done.
Counting objects: 100% (5/5), done.
Delta compression using up to 12 threads
Compressing objects: 100% (3/3), done.
Writing objects: 100% (3/3), 391 bytes | 391.00 KiB/s, done.
Total 3 (delta 2), reused 0 (delta 0), pack-reused 0
remote: Resolving deltas: 100% (2/2), completed with 2 local objects.
To https://github.com/srinivasa-vasu/ybdb-vanguard.git
   eb1bb44..5e2b86a  main -> main
Workspace initialized.
```

</details>

Choose the exercise index and launch the repo using [Open in Gitpod](#getting-started-with-gitpod) action.

## Query tuning tips and tricks
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
</div>

[sql universe:](init-qt/README.md)
This will help you get started with query tuning and have a better understanding of the distributed sql universe.

```bash
./run.sh
```
Choose the exercise index and launch the repo using [Open in Gitpod](#getting-started-with-gitpod) action.

## Development innerloop workflow
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
</div>

[inner loop:](init-iloop/README.md)
This will explore the development innerloop workflow and guide bulding an application from scratch. This provides a hands-on experience of interacting with yugabyte db.

```bash
./run.sh
```
Choose the exercise index and launch the repo using [Open in Gitpod](#getting-started-with-gitpod) action.

## Java microservices
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
</div>

[java microservices:](https://github.com/srinivasa-vasu/yb-ms-data)
This will explore the java microservices like spring boot, quarkus, and micronaut integration with yugabytedb.

## Java testcontainers
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
</div>

[testcontainers:](https://github.com/srinivasa-vasu/ybdb-boot-data)
This will explore the java testcontainers integration with yugabytedb.

## Securing Spring Boot Microservices
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
</div>

[secure by default:](https://github.com/srinivasa-vasu/ybdb-sealed-secrets)
This will explore securing Spring Boot application with YugabyteDB over TLS using the native cloud secret management services

## Data migration workflow from mysql to ybdb
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
</div>

[voyager:](init-voyager/README.md)
This will explore the voyager tool to migrate mysql to yugabytedb.

```bash
./run.sh
```
Choose the exercise index and launch the repo using [Open in Gitpod](#getting-started-with-gitpod) action.

## Change data capture(CDC) workflow from ybdb to postgres
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
</div>

[cdc:](init-cdc/README.md)
This will explore yugabytedb's change data capture.

```bash
./run.sh
```
Choose the exercise index and launch the repo using [Open in Gitpod](#getting-started-with-gitpod) action.

## Change data capture(CDC) streaming workflow from ysql to ycql
<div align="left">

![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
</div>

[cdc-stream:](https://github.com/srinivasa-vasu/yb-cdc-streams)
This will explore spring cloud stream microservices based cdc integration from ysql to ycql through a supplier-processor-consumer pattern.

## Data distribution and scalability
<div align="left">

![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
</div>

[scale out:](init-scale/README.md)
This will explore yugabytedb's data distribution and horizontal scalability.

```bash
./run.sh
```
Choose the exercise index and launch the repo using [Open in Gitpod](#getting-started-with-gitpod) action.

## Data replication, fault tolerance and high availability
<div align="left">

![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
</div>

[chaos engineering:](init-ft/README.md)
This will explore yugabytedb's fault tolerance and high availability.

```bash
./run.sh
```
Choose the exercise index and launch the repo using [Open in Gitpod](#getting-started-with-gitpod) action.
