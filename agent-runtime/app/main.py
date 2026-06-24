import os

import pika
from fastapi import FastAPI
from fastapi.responses import JSONResponse

RABBITMQ_URL = os.getenv("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/")

app = FastAPI(title="agent-runtime")


def _check_mq() -> tuple[bool, str]:
    try:
        params = pika.URLParameters(RABBITMQ_URL)
        params.socket_timeout = 5
        connection = pika.BlockingConnection(params)
        connection.close()
        return True, "ok"
    except Exception as e:
        return False, f"error: {e}"


@app.get("/health")
async def health():
    mq_ok, mq_msg = _check_mq()
    body = {"status": "UP" if mq_ok else "DOWN", "mq": mq_msg}
    return JSONResponse(status_code=200 if mq_ok else 503, content=body)
