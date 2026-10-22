from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse, Response
import httpx
import json
from typing import Dict, Any, List, Optional
import boto3
import re
import os
import uuid
from sqlalchemy import (
    create_engine,
    MetaData,
    Table,
    Column,
    String,
    Text,
    inspect,
    text,
)
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.sql import select, insert, update
import hashlib
import hmac
from okta_jwt_verifier import AccessTokenVerifier
from okta_jwt_verifier.jwt_utils import JWTUtils
from fastapi.middleware.cors import CORSMiddleware
import aiohttp
from anyio import to_thread

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allows all origins
    allow_credentials=True,
    allow_methods=["*"],  # Allows all methods
    allow_headers=["*"],  # Allows all headers
    expose_headers=["X-Session-Id"],  # Expose the X-Session-Id header
)

LITELLM_ENDPOINT = "http://localhost:4000"
LITELLM_CHAT = f"{LITELLM_ENDPOINT}/v1/chat/completions"

# Headers that must not be copied from a LiteLLM response onto ours: httpx/aiohttp have already
# decompressed and de-chunked the body, so the upstream encoding and length no longer apply.
HOP_BY_HOP_HEADERS = {
    "content-length",
    "transfer-encoding",
    "content-encoding",
    "connection",
    "keep-alive",
    "server",
    "date",
}


def relay_headers(headers) -> Dict[str, str]:
    return {k: v for k, v in headers.items() if k.lower() not in HOP_BY_HOP_HEADERS}


print(f"AWS_REGION: {os.getenv('AWS_REGION')}")
print(f"AWS_DEFAULT_REGION: {os.getenv('AWS_DEFAULT_REGION')}")
bedrock_client = boto3.client("bedrock-agent")

db_engine = None
metadata = MetaData()
chat_sessions = None

OKTA_ISSUER = os.environ.get("OKTA_ISSUER")
OKTA_AUDIENCE = os.environ.get("OKTA_AUDIENCE")
MASTER_KEY = os.environ.get("MASTER_KEY")

# Create a verifier instance for Access Tokens
access_token_verifier = None
if OKTA_AUDIENCE and OKTA_ISSUER:
    access_token_verifier = AccessTokenVerifier(
        issuer=OKTA_ISSUER, audience=OKTA_AUDIENCE
    )
else:
    print(
        "OKTA_AUDIENCE or OKTA_ISSUER are empty. Support for Okta JWT Auth is disabled."
    )


def setup_database():
    to_thread.current_default_thread_limiter().total_tokens = 1000
    print("Thread limiter configured")
    print("setting up database")
    try:
        database_url = os.environ.get("DATABASE_MIDDLEWARE_URL")
        if not database_url:
            print("DATABASE_MIDDLEWARE_URL environment variable not set")
            raise ValueError("DATABASE_MIDDLEWARE_URL environment variable not set")

        # Parse the URL to get base connection to postgres database
        url_parts = database_url.rsplit("/", 1)
        base_url = f"{url_parts[0]}/postgres"
        temp_engine = create_engine(base_url)

        # Check if middleware database exists
        with temp_engine.connect() as conn:
            conn.execute(text("COMMIT"))  # Close any open transaction
            result = conn.execute(
                text("SELECT 1 FROM pg_database WHERE datname = 'middleware'")
            )
            if not result.scalar():
                # Database doesn't exist, create it
                conn.execute(text("COMMIT"))  # Ensure we're not in a transaction
                conn.execute(text("CREATE DATABASE middleware"))
                print("Created middleware database")

        # Now connect to the middleware database using modified URL
        engine = create_engine(f"{url_parts[0]}/middleware")
        metadata_obj = MetaData()

        # Rest of your existing code remains the same
        with engine.begin() as conn:
            inspector = inspect(engine)
            if "chat_sessions" not in inspector.get_table_names():
                chat_sessions_table = Table(
                    "chat_sessions",
                    metadata_obj,
                    Column("session_id", String, primary_key=True),
                    Column("chat_history", Text),
                    Column("api_key_hash", String),
                )
                metadata_obj.create_all(engine)
                print("Created chat_sessions table")
            else:
                chat_sessions_table = Table(
                    "chat_sessions", metadata_obj, autoload_with=engine
                )
                columns = [c.name for c in chat_sessions_table.columns]
                if "api_key_hash" not in columns:
                    conn.execute(
                        text(
                            "ALTER TABLE chat_sessions ADD COLUMN api_key_hash VARCHAR;"
                        )
                    )
                else:
                    print("chat_sessions table already exists with api_key_hash column")

            # Check and create index within the same transaction
            indexes = inspector.get_indexes("chat_sessions")
            index_names = [idx["name"] for idx in indexes]

            if "idx_chat_sessions_api_key_hash" not in index_names:
                print("Creating index idx_chat_sessions_api_key_hash")
                conn.execute(
                    text(
                        "CREATE INDEX idx_chat_sessions_api_key_hash ON chat_sessions (api_key_hash)"
                    )
                )
                print("Index created successfully")

        # Verify table exists after transaction commits
        with engine.connect() as conn:
            result = conn.execute(
                text(
                    "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'chat_sessions')"
                )
            )
            if not result.scalar():
                raise Exception(
                    "Table creation failed - table does not exist after create_all()"
                )
            print("Table verification successful")

        return engine, chat_sessions_table

    except SQLAlchemyError as e:
        print(f"Database setup error: {str(e)}")
        raise
    except Exception as e:
        print(f"Database setup error: {str(e)}")
        raise


@app.on_event("startup")
async def startup_event():
    print("doing startup_event")
    global db_engine, chat_sessions
    db_engine, chat_sessions = setup_database()


def hash_api_key(api_key: str) -> str:
    return hashlib.sha256(api_key.encode("utf-8")).hexdigest()


def get_session_data(session_id: str) -> Optional[Dict[str, Any]]:
    with db_engine.connect() as conn:
        stmt = select(chat_sessions.c.chat_history, chat_sessions.c.api_key_hash).where(
            chat_sessions.c.session_id == session_id
        )
        result = conn.execute(stmt).fetchone()
        if result:
            return {
                "chat_history": json.loads(result[0]) if result[0] else None,
                "api_key_hash": result[1],
            }
    return None


def create_chat_history(
    session_id: str, chat_history: List[Dict[str, str]], api_key_hash: str
):
    with db_engine.connect() as conn:
        stmt = insert(chat_sessions).values(
            session_id=session_id,
            chat_history=json.dumps(chat_history),
            api_key_hash=api_key_hash,
        )
        conn.execute(stmt)
        conn.commit()


def update_chat_history(session_id: str, chat_history: List[Dict[str, str]]):
    with db_engine.connect() as conn:
        stmt = (
            update(chat_sessions)
            .where(chat_sessions.c.session_id == session_id)
            .values(chat_history=json.dumps(chat_history))
        )
        conn.execute(stmt)
        conn.commit()


def parse_prompt_arn(arn: str):
    if "prompt/" not in arn:
        return None, None

    after_prompt = arn.split("prompt/", 1)[1]

    if ":" in after_prompt:
        prompt_id, prompt_version = after_prompt.split(":", 1)
        return prompt_id, prompt_version
    else:
        return after_prompt, None


def validate_prompt_variables(template_text: str, variables: Dict[str, Any]):
    found_placeholders = re.findall(r"{{\s*(\w+)\s*}}", template_text)
    placeholders_set = set(found_placeholders)
    variables_set = set(variables.keys())

    if placeholders_set != variables_set:
        detail_message = {
            "message": f"Prompt variable mismatch. Template placeholders: {placeholders_set}. Provided variables: {variables_set}."
        }
        raise HTTPException(status_code=400, detail=detail_message)


def construct_prompt_text_from_variables(template_text: str, variables: dict) -> str:
    for var_name, var_value in variables.items():
        value = var_value.get("text", "")
        template_text = template_text.replace(f"{{{{{var_name}}}}}", value)
    return template_text


@app.get("/")
@app.get("/bedrock/health/liveliness")
async def health_check():
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                f"{LITELLM_ENDPOINT}/health/liveliness", timeout=5.0
            )
            if response.status_code == 200:
                return JSONResponse(
                    content={"status": "healthy", "litellm": "connected"}
                )
            else:
                return JSONResponse(
                    status_code=503, content={"status": "unhealthy", "litellm": "error"}
                )
    except Exception as e:
        return JSONResponse(
            status_code=503,
            content={"status": "unhealthy", "litellm": "disconnected", "error": str(e)},
        )


async def get_chat_stream(
    api_key: str,
    data: dict,
    session_id: str,
    chat_history: list,
    history_enabled: bool,
):
    """
    Returns a StreamingResponse that continuously yields messages from the LLM endpoint
    using aiohttp, and also returns the upstream headers in the response.
    """

    # Semgrep incorrectly marks this method as unused
    # nosemgrep
    async def read_linewise(aiohttp_body, chunk_size=1024):
        """
        Reads raw chunks from the aiohttp response body and yields complete lines.
        """
        buffer = ""
        async for chunk in aiohttp_body.iter_chunked(chunk_size):
            buffer += chunk.decode("utf-8")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                yield line
        # If anything remains in the buffer, yield it as a final line
        if buffer:
            yield buffer

    # We create our session manually (instead of `async with`) so that we can
    # keep it open for the entire duration of the stream and close it later.
    session = aiohttp.ClientSession()

    # Make the POST request up front (so we can capture headers right away).
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    response = await session.post(
        f"{LITELLM_ENDPOINT}/v1/chat/completions",
        json=data,
        headers=headers,
        timeout=None,  # or aiohttp.ClientTimeout(...)
    )

    # Extract upstream headers
    response_headers = dict(response.headers)

    # Define an async generator that will yield SSE data from the response.
    async def stream_events():
        assistant_content_parts = []
        first_chunk = True

        try:
            # Read the response line by line
            async for line in read_linewise(response.content):
                line = line.strip()
                if not line:
                    continue

                # Check for sentinel lines
                if line.startswith("data: [DONE]"):
                    # Forward the terminator: OpenAI-compatible clients wait for it
                    yield b"data: [DONE]\n\n"
                    break

                # The OpenAI-like endpoints often prepend "data: " before JSON
                if line.startswith("data: "):
                    line = line[len("data: ") :]

                # Attempt to parse JSON from the line
                try:
                    chunk_dict = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Inject session_id only into the first chunk if you wish
                if first_chunk and history_enabled:
                    chunk_dict["session_id"] = session_id
                first_chunk = False

                # Yield as a Server-Sent Event
                yield f"data: {json.dumps(chunk_dict)}\n\n".encode("utf-8")

                # Optionally accumulate partial content
                choice = chunk_dict["choices"][0]
                delta = choice.get("delta", {})
                finish_reason = choice.get("finish_reason", None)  # noqa: F841

                if history_enabled and "content" in delta and delta["content"]:
                    assistant_content_parts.append(delta["content"])

                # You could break if finish_reason == "stop", if desired
                # if finish_reason == "stop":
                #     break

            # Once streaming ends (for any reason), finalize chat history if desired
            if history_enabled and assistant_content_parts:
                assistant_message = {
                    "role": "assistant",
                    "content": "".join(assistant_content_parts),
                }
                chat_history.append(assistant_message)
                update_chat_history(session_id, chat_history)

        finally:
            # Very important: Close the session once we're done streaming.
            await session.close()

    # Build the StreamingResponse using our generator
    sresponse = StreamingResponse(stream_events(), media_type="text/event-stream")

    # Attach upstream headers to our outgoing response
    for k, v in relay_headers(response_headers).items():
        sresponse.headers[k] = v

    return sresponse


@app.post("/v1/chat/completions")
@app.post("/chat/completions")
async def proxy_request(request: Request):
    body = await request.body()

    try:
        data = json.loads(body)
        is_streaming = data.get("stream", False)

        enable_history = data.pop("enable_history", False)
        session_id = data.pop("session_id", None)
        history_enabled = (session_id is not None) or enable_history

        # Get API key from headers
        api_key = request.headers.get("Authorization", "").replace("Bearer ", "")
        if not api_key:
            raise HTTPException(
                status_code=401,
                detail={"error": "Missing or invalid Authorization header"},
            )
        provided_hash = hash_api_key(api_key)

        # Prepare or load chat_history
        if history_enabled:
            if session_id is not None:
                # Retrieve or verify existing session
                session_data = get_session_data(session_id)
                if session_data is not None:
                    if session_data["api_key_hash"] != provided_hash:
                        raise HTTPException(
                            status_code=401,
                            detail={
                                "error": "Unauthorized: API key does not match session owner"
                            },
                        )
                    chat_history = session_data["chat_history"] or []
                else:
                    chat_history = []
                    create_chat_history(session_id, chat_history, provided_hash)
            else:
                # No session_id but enable_history = True, so create a new session
                session_id = str(uuid.uuid4())
                chat_history = []
                create_chat_history(session_id, chat_history, provided_hash)
        else:
            # History not enabled: start with empty
            chat_history = []

        # Merge incoming messages into chat_history in original order
        new_messages = data.get("messages", [])
        for msg in new_messages:
            chat_history.append(msg)

        # Now data["messages"] should be the entire conversation the model sees
        data["messages"] = chat_history

        # ---------------------------------------------------------------------
        # Handle optional "Bedrock Prompt" logic (unchanged from your snippet):
        # ---------------------------------------------------------------------
        model_id = data.get("model")
        prompt_variables = data.pop("promptVariables", {})
        final_prompt_text = None
        if model_id and model_id.startswith("arn:aws:bedrock:"):
            prompt_id, prompt_version = parse_prompt_arn(model_id)
            if prompt_id:
                if prompt_version:
                    prompt = bedrock_client.get_prompt(
                        promptIdentifier=prompt_id, promptVersion=prompt_version
                    )
                else:
                    prompt = bedrock_client.get_prompt(promptIdentifier=prompt_id)

                variants = prompt.get("variants", [])
                variant = variants[0]
                template_text = variant["templateConfiguration"]["text"]["text"]

                validate_prompt_variables(template_text, prompt_variables)
                final_prompt_text = construct_prompt_text_from_variables(
                    template_text, prompt_variables
                )

                if "modelId" in variant:
                    data["model"] = variant["modelId"]

        if final_prompt_text:
            data["messages"] = [{"role": "user", "content": final_prompt_text}]

        # ---------------------------------------------------------------------
        # Stream vs. Non-Stream logic
        # ---------------------------------------------------------------------
        if is_streaming:
            return await get_chat_stream(
                api_key, data, session_id, chat_history, history_enabled
            )
        else:
            headers = {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            }
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{LITELLM_ENDPOINT}/v1/chat/completions",
                    headers=headers,
                    json=data,
                ) as resp:
                    response_headers = relay_headers(resp.headers)
                    response_dict = await resp.json()

            # If there's a response from the assistant, save it to history
            if response_dict.get("choices"):
                assistant_message = response_dict["choices"][0]["message"]
                if history_enabled:
                    chat_history.append(
                        {"role": "assistant", "content": assistant_message["content"]}
                    )
                    update_chat_history(session_id, chat_history)

            # Return session_id in the response if we have one
            if session_id:
                response_dict["session_id"] = session_id

            return Response(
                content=json.dumps(response_dict),
                headers=response_headers,
                media_type="application/json",
            )

    except json.JSONDecodeError:
        return Response(
            content=json.dumps({"error": "Invalid JSON"}),
            status_code=400,
            media_type="application/json",
        )
    except HTTPException as he:
        return JSONResponse(status_code=he.status_code, content=he.detail)
    except Exception as e:
        return Response(
            content=json.dumps({"error": str(e)}),
            status_code=500,
            media_type="application/json",
        )


def convert_openai_to_bedrock_history(
    openai_history: List[Dict[str, str]],
) -> Dict[str, Any]:
    system_messages = []
    bedrock_messages = []

    for msg in openai_history:
        role = msg.get("role")
        content = msg.get("content", "")
        if role == "system":
            system_messages.append({"text": content})
        else:
            bedrock_messages.append({"role": role, "content": [{"text": content}]})

    return {"messages": bedrock_messages, "system": system_messages}


@app.post("/bedrock/chat-history")
async def get_bedrock_chat_history(request: Request):
    body = await request.json()
    session_id = body.get("session_id")
    if not session_id:
        raise HTTPException(status_code=400, detail="session_id is required")

    # We must verify the API key for this history as well
    auth_header = request.headers.get("Authorization")
    if auth_header and auth_header.startswith("Bearer "):
        api_key = auth_header[len("Bearer ") :]
    else:
        raise HTTPException(
            status_code=401, detail={"error": "Missing or invalid Authorization header"}
        )
    provided_hash = hash_api_key(api_key)

    session_data = get_session_data(session_id)
    if not session_data or session_data["api_key_hash"] != provided_hash:
        raise HTTPException(
            status_code=401,
            detail={"error": "Unauthorized: API key does not match session owner"},
        )

    chat_history = session_data["chat_history"]
    if chat_history is None:
        return {"messages": [], "system": []}
    bedrock_format = convert_openai_to_bedrock_history(chat_history)
    return bedrock_format


@app.post("/chat-history")
async def get_openai_chat_history(request: Request):
    body = await request.json()
    session_id = body.get("session_id")
    if not session_id:
        raise HTTPException(status_code=400, detail="session_id is required")

    # Verify the API key
    auth_header = request.headers.get("Authorization")
    if auth_header and auth_header.startswith("Bearer "):
        api_key = auth_header[len("Bearer ") :]
    else:
        raise HTTPException(
            status_code=401, detail={"error": "Missing or invalid Authorization header"}
        )
    provided_hash = hash_api_key(api_key)

    session_data = get_session_data(session_id)
    if not session_data or session_data["api_key_hash"] != provided_hash:
        raise HTTPException(
            status_code=401,
            detail={"error": "Unauthorized: API key does not match session owner"},
        )

    chat_history = session_data["chat_history"]
    if chat_history is None:
        chat_history = []
    return {"messages": chat_history}


@app.post("/session-ids")
async def list_session_ids_for_api_key(request: Request):
    # Verify the API key
    auth_header = request.headers.get("Authorization")
    if auth_header and auth_header.startswith("Bearer "):
        api_key = auth_header[len("Bearer ") :]
    else:
        raise HTTPException(
            status_code=401, detail={"error": "Missing or invalid Authorization header"}
        )

    provided_hash = hash_api_key(api_key)

    # Query all session_ids for this api_key_hash
    with db_engine.connect() as conn:
        stmt = select(chat_sessions.c.session_id).where(
            chat_sessions.c.api_key_hash == provided_hash
        )
        results = conn.execute(stmt).fetchall()

    session_ids = [row[0] for row in results]

    return {"session_ids": session_ids}


async def caller_is_proxy_admin(client: httpx.AsyncClient, token: str) -> bool:
    """True for the master key, or a key whose LiteLLM user has the proxy_admin role."""
    if MASTER_KEY and hmac.compare_digest(token, MASTER_KEY):
        return True
    # /key/info without a key parameter describes the calling key
    key_info = await client.get(
        f"{LITELLM_ENDPOINT}/key/info",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10.0,
    )
    if key_info.status_code != 200:
        return False
    user_id = (key_info.json().get("info") or {}).get("user_id")
    if not user_id or not MASTER_KEY:
        return False
    user_info = await client.get(
        f"{LITELLM_ENDPOINT}/user/info",
        params={"user_id": user_id},
        headers={"Authorization": f"Bearer {MASTER_KEY}"},
        timeout=10.0,
    )
    if user_info.status_code != 200:
        return False
    return (user_info.json().get("user_info") or {}).get("user_role") == "proxy_admin"


# LiteLLM lets non-admin keys create keys for any user (https://github.com/BerriAI/litellm/issues/7336),
# so key creation through the gateway is limited to admins. Non-admin users get their key via /user/new.
@app.post("/key/generate")
async def forward_key_generate(request: Request):
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=401, detail={"error": "Missing or invalid Authorization header"}
        )
    async with httpx.AsyncClient() as client:
        if not await caller_is_proxy_admin(client, auth_header[len("Bearer ") :]):
            return JSONResponse(
                status_code=403,
                content={"error": "Only admins can generate keys"},
            )
        response = await client.post(
            f"{LITELLM_ENDPOINT}/key/generate",
            content=await request.body(),
            headers=request.headers,
        )
        return Response(
            content=response.content,
            status_code=response.status_code,
            headers=relay_headers(response.headers),
        )


@app.post("/user/new")
async def forward_user_new(request: Request):
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=401, detail={"error": "Missing or invalid Authorization header"}
        )

    token = auth_header[len("Bearer ") :]
    final_headers = dict(request.headers)
    request_body = await request.body()
    body_json = json.loads(request_body)

    if not token.startswith("sk-") and access_token_verifier:
        print("token is not api key, assume it is JWT")
        # Handle as JWT
        try:
            await access_token_verifier.verify(token)
            print("token is verified.")
        except Exception as e:
            print(f"exception: {e}")
            # If the JWT verification fails, user is not authorized.
            raise HTTPException(
                status_code=401, detail={"error": "Invalid or expired token"}
            ) from e

        headers, claims, signing_input, signature = JWTUtils.parse_token(token)

        sub = claims.get("sub")
        print(f"sub: {sub}")
        if not sub:
            raise HTTPException(
                status_code=403, detail={"error": "No sub claim found in the token"}
            )

        # For random Okta users, we want to bind their okta sub/id to their litellm user_id. So that the relationship between okta users and litellm users is 1:1
        # We also want random Okta users to not be able to make themselves admins, so we lock their user_role to "internal_user"
        # Only someone with the master key (or users/keys derived from the master key) will be able to perform any admin operations
        # At a later point, we can decide that someone with a specific Okta claim is able to act as an admin and bypass these restrictions without needing the master key
        # Right now, users can give themselves any max_budget, tpm_limit, rpm_limit, max_parallel_requests, or teams. At a later point, we can lock these down more, or make a default configurable in the deployment.
        body_json["user_email"] = sub
        body_json["user_id"] = sub
        body_json["user_role"] = "internal_user"
        print(f"body_json: {body_json}")
        request_body = json.dumps(body_json).encode()
        final_headers["content-length"] = str(len(request_body))
        final_headers["authorization"] = f"Bearer {MASTER_KEY}"

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{LITELLM_ENDPOINT}/user/new",
            content=request_body,
            headers=final_headers,
        )
        return Response(
            content=response.content,
            status_code=response.status_code,
            headers=relay_headers(response.headers),
        )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=3000)
