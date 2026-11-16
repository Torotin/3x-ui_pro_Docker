import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
PYTHON_ROOT = ROOT / "docker-proxy" / "3x-ui" / "scripts" / "python"
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from xui_runtime.apply import inbound as inbound_module  # noqa: E402
from xui_runtime.apply.inbound import (  # noqa: E402
    repair_inbound_client_tg_ids_db,
    repair_inbound_vless_client_flows_db,
    repair_shared_client_db,
)
from xui_runtime.desired import build_desired_state  # noqa: E402


class TestDbRepairModeGuards(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmp.name) / "x-ui.db"
        con = sqlite3.connect(self.db_path, timeout=10.0)
        con.execute(
            "create table clients (email text, uuid text, password text, auth text, flow text, sub_id text)"
        )
        con.execute(
            "create table inbounds (id integer primary key, settings text)"
        )
        con.execute(
            "insert into clients (email, uuid, password, auth, flow, sub_id) values (?,?,?,?,?,?)",
            ("autogen", "old", "p", "a", "", "sub"),
        )
        settings = json.dumps(
            {
                "clients": [
                    {"email": "autogen", "flow": "", "tgId": "123"},
                ]
            }
        )
        con.execute("insert into inbounds (id, settings) values (1, ?)", (settings,))
        con.commit()
        con.close()
        self.env = {"XUI_DB_PATH": str(self.db_path)}

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_check_mode_does_not_write_sqlite(self) -> None:
        calls: list[tuple[str, tuple[object, ...]]] = []

        class TrackingConnection:
            def __init__(self, *args, **kwargs) -> None:
                self._con = sqlite3.connect(*args, **kwargs)

            def execute(self, sql: str, params: tuple[object, ...] = ()) -> object:
                calls.append((sql, params))
                return self._con.execute(sql, params)

            def commit(self) -> None:
                calls.append(("commit", ()))
                self._con.commit()

            def close(self) -> None:
                self._con.close()

        with patch(
            "xui_runtime.apply.inbound.sqlite3.connect",
            side_effect=lambda *a, **k: TrackingConnection(*a, **k),
        ):
            repair_shared_client_db(
                "autogen",
                "new",
                "sub",
                "flow",
                "p2",
                "a2",
                env=self.env,
                mode="check",
            )
            self.assertEqual(calls, [])
            self.assertEqual(
                repair_inbound_client_tg_ids_db(env=self.env, mode="plan"),
                0,
            )
            desired = build_desired_state(self.env)
            self.assertEqual(
                repair_inbound_vless_client_flows_db(
                    "1",
                    "2",
                    "",
                    desired,
                    env=self.env,
                    mode="check",
                ),
                0,
            )
        con = sqlite3.connect(self.db_path, timeout=10.0)
        row = con.execute(
            "select uuid from clients where email='autogen'"
        ).fetchone()
        con.close()
        self.assertEqual(row[0], "old")

    def test_apply_mode_repairs_tg_id(self) -> None:
        changed = repair_inbound_client_tg_ids_db(env=self.env, mode="apply")
        self.assertEqual(changed, 1)
        con = sqlite3.connect(self.db_path, timeout=10.0)
        settings_text = con.execute(
            "select settings from inbounds where id=1"
        ).fetchone()[0]
        con.close()
        settings = json.loads(settings_text)
        self.assertEqual(settings["clients"][0]["tgId"], 123)

    def test_repair_tg_ids_issues_wal_checkpoint_after_write(self) -> None:
        with patch.object(
            inbound_module,
            "_sqlite_commit_with_checkpoint",
            wraps=inbound_module._sqlite_commit_with_checkpoint,
        ) as checkpoint:
            self.assertEqual(
                repair_inbound_client_tg_ids_db(env=self.env, mode="apply"), 1
            )
        checkpoint.assert_called_once()

    def test_repair_shared_client_issues_wal_checkpoint_after_write(self) -> None:
        with patch.object(
            inbound_module,
            "_sqlite_commit_with_checkpoint",
            wraps=inbound_module._sqlite_commit_with_checkpoint,
        ) as checkpoint:
            repair_shared_client_db(
                "autogen",
                "new-uuid",
                "sub",
                "flow",
                "p2",
                "a2",
                env=self.env,
                mode="apply",
            )
        checkpoint.assert_called_once()

    def test_repair_skips_checkpoint_when_no_write(self) -> None:
        con = sqlite3.connect(self.db_path, timeout=10.0)
        settings = json.dumps(
            {"clients": [{"email": "autogen", "flow": "", "tgId": 123}]}
        )
        con.execute("update inbounds set settings=? where id=1", (settings,))
        con.commit()
        con.close()
        with patch.object(
            inbound_module,
            "_sqlite_commit_with_checkpoint",
            wraps=inbound_module._sqlite_commit_with_checkpoint,
        ) as checkpoint:
            self.assertEqual(
                repair_inbound_client_tg_ids_db(env=self.env, mode="apply"), 0
            )
        checkpoint.assert_not_called()


if __name__ == "__main__":
    unittest.main()