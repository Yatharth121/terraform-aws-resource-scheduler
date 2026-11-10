import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))


class FakePaginator:
    def __init__(self, pages):
        self.pages = pages

    def paginate(self, **_kwargs):
        return iter(self.pages)


class FakeClient:
    """Records calls and serves canned paginator pages."""

    def __init__(self, pages=None, describe_services=None):
        self.pages = pages or {}
        self._describe_services = describe_services or {}
        self.calls = []

    def get_paginator(self, name):
        return FakePaginator(self.pages.get(name, []))

    def describe_services(self, cluster, services, include):
        return {"services": [s for s in self._describe_services.get(cluster, []) if s["serviceArn"] in services]}

    def __getattr__(self, name):
        def record(**kwargs):
            self.calls.append((name, kwargs))
            return {}

        return record


@pytest.fixture
def sched(monkeypatch):
    monkeypatch.setenv("SCHEDULE_TAG_KEY", "Schedule")
    monkeypatch.setenv("SCHEDULE_TAG_VALUE", "office-hours")
    monkeypatch.setenv("DRY_RUN", "false")
    import scheduler

    return importlib.reload(scheduler)


TAG = [{"Key": "Schedule", "Value": "office-hours"}]


def ec2_page(*instances):
    return {"describe_instances": [{"Reservations": [{"Instances": list(instances)}]}]}


def test_ec2_stop_skips_asg_members(sched):
    ec2 = FakeClient(
        ec2_page(
            {"InstanceId": "i-1", "Tags": TAG},
            {"InstanceId": "i-2", "Tags": TAG + [{"Key": "aws:autoscaling:groupName", "Value": "web"}]},
        )
    )
    assert sched.handle_ec2(ec2, "stop") == ["i-1"]
    assert ec2.calls == [("stop_instances", {"InstanceIds": ["i-1"]})]


def test_ec2_start_batches_by_50(sched):
    instances = [{"InstanceId": f"i-{n}", "Tags": TAG} for n in range(120)]
    ec2 = FakeClient(ec2_page(*instances))
    sched.handle_ec2(ec2, "start")
    assert [len(c[1]["InstanceIds"]) for c in ec2.calls] == [50, 50, 20]


def test_rds_handles_clusters_and_skips_members_and_replicas(sched):
    rds = FakeClient(
        {
            "describe_db_clusters": [
                {"DBClusters": [{"DBClusterIdentifier": "aurora-1", "Status": "available", "TagList": TAG}]}
            ],
            "describe_db_instances": [
                {
                    "DBInstances": [
                        {"DBInstanceIdentifier": "aurora-1-a", "DBClusterIdentifier": "aurora-1", "DBInstanceStatus": "available", "TagList": TAG},
                        {"DBInstanceIdentifier": "pg-1", "DBInstanceStatus": "available", "TagList": TAG},
                        {"DBInstanceIdentifier": "pg-replica", "ReadReplicaSourceDBInstanceIdentifier": "pg-x", "DBInstanceStatus": "available", "TagList": TAG},
                        {"DBInstanceIdentifier": "untagged", "DBInstanceStatus": "available", "TagList": []},
                    ]
                }
            ],
        }
    )
    assert sched.handle_rds(rds, "stop") == ["aurora-1", "pg-1"]
    assert ("stop_db_cluster", {"DBClusterIdentifier": "aurora-1"}) in rds.calls
    assert ("stop_db_instance", {"DBInstanceIdentifier": "pg-1"}) in rds.calls
    assert len(rds.calls) == 2


def test_rds_start_ignores_already_running(sched):
    rds = FakeClient(
        {
            "describe_db_clusters": [{"DBClusters": []}],
            "describe_db_instances": [
                {"DBInstances": [{"DBInstanceIdentifier": "pg-1", "DBInstanceStatus": "available", "TagList": TAG}]}
            ],
        }
    )
    assert sched.handle_rds(rds, "start") == []
    assert rds.calls == []


def ecs_client(desired, extra_tags=None):
    arn = "arn:aws:ecs:ca-central-1:111111111111:service/c1/api"
    tags = [{"key": "Schedule", "value": "office-hours"}] + (extra_tags or [])
    return arn, FakeClient(
        {
            "list_clusters": [{"clusterArns": ["c1"]}],
            "list_services": [{"serviceArns": [arn]}],
        },
        describe_services={"c1": [{"serviceArn": arn, "desiredCount": desired, "tags": tags}]},
    )


def test_ecs_stop_records_desired_count(sched):
    arn, ecs = ecs_client(3)
    assert sched.handle_ecs(ecs, "stop") == [arn]
    assert ecs.calls == [
        ("tag_resource", {"resourceArn": arn, "tags": [{"key": "scheduler:desired-count", "value": "3"}]}),
        ("update_service", {"cluster": "c1", "service": arn, "desiredCount": 0}),
    ]


def test_ecs_start_restores_desired_count(sched):
    arn, ecs = ecs_client(0, [{"key": "scheduler:desired-count", "value": "3"}])
    sched.handle_ecs(ecs, "start")
    assert ecs.calls == [("update_service", {"cluster": "c1", "service": arn, "desiredCount": 3})]


def test_dry_run_changes_nothing(monkeypatch, sched):
    monkeypatch.setenv("DRY_RUN", "true")
    dry = importlib.reload(sched)
    ec2 = FakeClient(ec2_page({"InstanceId": "i-1", "Tags": TAG}))
    assert dry.handle_ec2(ec2, "stop") == ["i-1"]
    assert ec2.calls == []


def test_rejects_unknown_action(sched):
    with pytest.raises(ValueError):
        sched.run("reboot", {})
