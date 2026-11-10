"""Start and stop tagged AWS resources on a schedule.

Invoked by EventBridge Scheduler with {"action": "start"} or {"action": "stop"}.
Handles EC2 instances, RDS instances, Aurora clusters and ECS services that carry
the configured schedule tag.
"""

import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

TAG_KEY = os.environ.get("SCHEDULE_TAG_KEY", "Schedule")
TAG_VALUE = os.environ.get("SCHEDULE_TAG_VALUE", "office-hours")
DESIRED_COUNT_TAG = os.environ.get("ECS_DESIRED_COUNT_TAG", "scheduler:desired-count")
ENABLE_EC2 = os.environ.get("ENABLE_EC2", "true") == "true"
ENABLE_RDS = os.environ.get("ENABLE_RDS", "true") == "true"
ENABLE_ECS = os.environ.get("ENABLE_ECS", "true") == "true"
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"

ASG_TAG = "aws:autoscaling:groupName"


def _tags_to_dict(tags):
    return {t["Key"]: t["Value"] for t in tags or []}


def _ecs_tags_to_dict(tags):
    return {t["key"]: t["value"] for t in tags or []}


def _is_scheduled(tags):
    return tags.get(TAG_KEY) == TAG_VALUE


def _chunks(items, size):
    for i in range(0, len(items), size):
        yield items[i : i + size]


# ---------- EC2 ----------

def handle_ec2(ec2, action):
    wanted_state = "stopped" if action == "start" else "running"
    paginator = ec2.get_paginator("describe_instances")
    ids = []
    for page in paginator.paginate(
        Filters=[
            {"Name": f"tag:{TAG_KEY}", "Values": [TAG_VALUE]},
            {"Name": "instance-state-name", "Values": [wanted_state]},
        ]
    ):
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                tags = _tags_to_dict(instance.get("Tags"))
                if ASG_TAG in tags:
                    # Auto Scaling would replace a stopped instance. Schedule the ASG instead.
                    logger.info("Skipping %s: managed by ASG %s", instance["InstanceId"], tags[ASG_TAG])
                    continue
                ids.append(instance["InstanceId"])

    for batch in _chunks(ids, 50):
        if DRY_RUN:
            logger.info("[dry run] would %s EC2 %s", action, batch)
        elif action == "start":
            ec2.start_instances(InstanceIds=batch)
        else:
            ec2.stop_instances(InstanceIds=batch)
    return ids


# ---------- RDS ----------

def handle_rds(rds, action):
    changed = []

    # Aurora clusters are started and stopped as a whole.
    for page in rds.get_paginator("describe_db_clusters").paginate():
        for cluster in page["DBClusters"]:
            if not _is_scheduled(_tags_to_dict(cluster.get("TagList"))):
                continue
            status = cluster["Status"]
            ident = cluster["DBClusterIdentifier"]
            if action == "stop" and status == "available":
                if not DRY_RUN:
                    rds.stop_db_cluster(DBClusterIdentifier=ident)
                changed.append(ident)
            elif action == "start" and status == "stopped":
                if not DRY_RUN:
                    rds.start_db_cluster(DBClusterIdentifier=ident)
                changed.append(ident)

    for page in rds.get_paginator("describe_db_instances").paginate():
        for db in page["DBInstances"]:
            if db.get("DBClusterIdentifier"):
                continue  # handled with its cluster
            if db.get("ReadReplicaSourceDBInstanceIdentifier") or db.get("ReadReplicaDBInstanceIdentifiers"):
                logger.info("Skipping %s: read replicas can't be stopped", db["DBInstanceIdentifier"])
                continue
            if not _is_scheduled(_tags_to_dict(db.get("TagList"))):
                continue
            status = db["DBInstanceStatus"]
            ident = db["DBInstanceIdentifier"]
            if action == "stop" and status == "available":
                if not DRY_RUN:
                    rds.stop_db_instance(DBInstanceIdentifier=ident)
                changed.append(ident)
            elif action == "start" and status == "stopped":
                if not DRY_RUN:
                    rds.start_db_instance(DBInstanceIdentifier=ident)
                changed.append(ident)
    return changed


# ---------- ECS ----------

def handle_ecs(ecs, action):
    changed = []
    cluster_arns = []
    for page in ecs.get_paginator("list_clusters").paginate():
        cluster_arns.extend(page["clusterArns"])

    for cluster in cluster_arns:
        service_arns = []
        for page in ecs.get_paginator("list_services").paginate(cluster=cluster):
            service_arns.extend(page["serviceArns"])

        for batch in _chunks(service_arns, 10):
            resp = ecs.describe_services(cluster=cluster, services=batch, include=["TAGS"])
            for svc in resp["services"]:
                tags = _ecs_tags_to_dict(svc.get("tags"))
                if not _is_scheduled(tags):
                    continue
                arn = svc["serviceArn"]
                desired = svc["desiredCount"]

                if action == "stop" and desired > 0:
                    # Remember the running size so "start" can restore it.
                    if not DRY_RUN:
                        ecs.tag_resource(resourceArn=arn, tags=[{"key": DESIRED_COUNT_TAG, "value": str(desired)}])
                        ecs.update_service(cluster=cluster, service=arn, desiredCount=0)
                    changed.append(arn)
                elif action == "start" and desired == 0:
                    restore = int(tags.get(DESIRED_COUNT_TAG, "1"))
                    if not DRY_RUN:
                        ecs.update_service(cluster=cluster, service=arn, desiredCount=restore)
                    changed.append(arn)
    return changed


# ---------- entry point ----------

def run(action, clients):
    if action not in ("start", "stop"):
        raise ValueError(f"action must be 'start' or 'stop', got {action!r}")

    result = {"action": action, "dry_run": DRY_RUN}
    if ENABLE_EC2:
        result["ec2"] = handle_ec2(clients["ec2"], action)
    if ENABLE_RDS:
        result["rds"] = handle_rds(clients["rds"], action)
    if ENABLE_ECS:
        result["ecs"] = handle_ecs(clients["ecs"], action)
    logger.info(json.dumps(result))
    return result


def handler(event, _context):
    import boto3  # imported here so unit tests don't need boto3

    clients = {name: boto3.client(name) for name in ("ec2", "rds", "ecs")}
    return run(event.get("action"), clients)
