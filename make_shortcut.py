"""Genera el archivo del Atajo de Apple "Claude" (sin firmar).
Acciones: Dictar texto -> Ejecutar script (ask.sh) -> Mostrar notificación.
"""
import os
import plistlib
import uuid

shell_uuid = str(uuid.uuid4()).upper()

actions = [
    {
        "WFWorkflowActionIdentifier": "is.workflow.actions.dictatetext",
        "WFWorkflowActionParameters": {
            "WFDictateTextStopListening": "After Pause",
            "WFSpeechLanguage": "es_MX",
        },
    },
    {
        "WFWorkflowActionIdentifier": "is.workflow.actions.runshellscript",
        "WFWorkflowActionParameters": {
            "UUID": shell_uuid,
            "Shell": "/bin/zsh",
            "Input": "stdin",
            "Script": os.path.expanduser("~/claude-voice/ask.sh"),
        },
    },
    {
        "WFWorkflowActionIdentifier": "is.workflow.actions.notification",
        "WFWorkflowActionParameters": {
            "WFNotificationActionTitle": "Claude",
            "WFNotificationActionBody": {
                "WFSerializationType": "WFTextTokenString",
                "Value": {
                    "string": "￼",
                    "attachmentsByRange": {
                        "{0, 1}": {
                            "Type": "ActionOutput",
                            "OutputName": "Shell Script Result",
                            "OutputUUID": shell_uuid,
                        }
                    },
                },
            },
        },
    },
]

workflow = {
    "WFWorkflowClientVersion": "2607.0.3",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {
        "WFWorkflowIconStartColor": 4282601983,
        "WFWorkflowIconGlyphNumber": 59511,
    },
    "WFWorkflowImportQuestions": [],
    "WFWorkflowTypes": [],
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowHasShortcutInputVariables": False,
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowName": "Claude",
    "WFWorkflowActions": actions,
}

with open("Claude-unsigned.shortcut", "wb") as f:
    plistlib.dump(workflow, f)
print("Claude-unsigned.shortcut generado")
