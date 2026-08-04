#!/usr/bin/env python3
"""Genera la configuracion efimera de AuthMe sin imprimir secretos."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import yaml


def required_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"Falta la variable requerida {name}")
    return value


def mapping(parent: dict, key: str) -> dict:
    value = parent.setdefault(key, {})
    if not isinstance(value, dict):
        raise SystemExit(f"La seccion {key} de AuthMe no es valida")
    return value


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Uso: configure-authme.py <config.yml>")

    config_path = Path(sys.argv[1])
    config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise SystemExit("La configuracion base de AuthMe no es valida")

    data_source = mapping(config, "DataSource")
    data_source.update(
        {
            "backend": "POSTGRESQL",
            "caching": True,
            "mySQLHost": required_env("AUTH_DB_HOST"),
            "mySQLPort": os.environ.get("AUTH_DB_PORT", "5432"),
            "mySQLUseSSL": True,
            "mySQLCheckServerCertificate": True,
            "mySQLUsername": required_env("AUTH_DB_USER"),
            "mySQLPassword": required_env("AUTH_DB_PASSWORD"),
            "mySQLDatabase": os.environ.get("AUTH_DB_NAME", "postgres"),
            "mySQLTablename": os.environ.get("AUTH_DB_TABLE", "authme"),
            # Un servidor pequeno no debe reservar las 10 conexiones predeterminadas.
            "poolSize": 3,
            "maxLifetime": 900,
        }
    )

    settings = mapping(config, "settings")
    settings["messagesLanguage"] = "es"
    settings["perPlayerLocale"] = True
    settings["useAsyncTasks"] = True
    settings["logLevel"] = "INFO"

    sessions = mapping(settings, "sessions")
    sessions["enabled"] = False

    restrictions = mapping(settings, "restrictions")
    restrictions.update(
        {
            "maxRegPerIp": 3,
            "minNicknameLength": 3,
            "maxNicknameLength": 32,
            # El punto es el prefijo predeterminado de usuarios Floodgate.
            "allowedNicknameCharacters": "[a-zA-Z0-9_.]*",
            "loginTimeout": 90,
            "registerTimeout": 120,
            # PacketEvents no es necesario para este despliegue.
            "ProtectInventoryBeforeLogIn": False,
            "DenyTabCompleteBeforeLogin": False,
        }
    )

    security = mapping(settings, "security")
    security.update(
        {
            "minPasswordLength": 10,
            "passwordMaxLength": 64,
            "passwordHash": "ARGON2ID",
            "legacyHashes": [],
        }
    )

    registration = mapping(settings, "registration")
    registration.update(
        {
            "enabled": True,
            "force": True,
            "type": "PASSWORD",
            "secondArg": "CONFIRMATION",
        }
    )

    # Los dialogs Java modernos no tienen compatibilidad garantizada en Bedrock;
    # ambos clientes usan /register y /login de forma consistente.
    dialog = mapping(registration, "dialog")
    mapping(dialog, "preJoin")["enable"] = False
    mapping(dialog, "postJoin")["enable"] = False

    auth_security = mapping(config, "Security")
    mapping(auth_security, "SQLProblem")["stopServer"] = True
    captcha = mapping(auth_security, "captcha")
    captcha.update({"useCaptcha": True, "maxLoginTry": 3})
    tempban = mapping(auth_security, "tempban")
    tempban.update(
        {
            "enableTempban": True,
            "maxLoginTries": 5,
            "tempbanLength": 30,
            "minutesBeforeCounterReset": 30,
        }
    )

    rendered = yaml.safe_dump(
        config,
        allow_unicode=True,
        default_flow_style=False,
        sort_keys=False,
    )
    config_path.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
