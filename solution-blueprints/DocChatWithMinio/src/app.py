# Copyright © Advanced Micro Devices, Inc., or its affiliates.
#
# SPDX-License-Identifier: MIT

import asyncio
import html
import logging
import urllib.parse

import gradio as gr
import uvicorn
from backend import KnowledgeBase
from config import GRADIO_PORT, TITLE
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response
from rag import run_rag

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize the Backend
kb = KnowledgeBase()

# Initialize the Server
app = FastAPI(title=TITLE or "Talk to your documents")


# HEALTH CHECKS
@app.get("/health")
@app.get("//health", include_in_schema=False)
async def health():
    return {"status": "ok"}


# API LOGIC
def get_documents_logic():
    return kb.list_documents()


def get_document_source_logic(document_name: str):
    return kb.get_document_source(document_name)


def process_rag_logic(files, question: str) -> str:
    if files:
        file_paths = [f.name if hasattr(f, "name") else f for f in files]
        kb.build(file_paths)

    final_answer = ""
    full_log = ""
    for chunk in run_rag(question, kb):
        full_log += chunk
        if "**Final Answer:**" in chunk:
            final_answer = chunk.split("**Final Answer:**")[1].strip()

    return final_answer if final_answer else full_log


@app.post("/process")
async def api_process(request: Request):
    try:
        data = await request.json()
        question = data.get("question", "")
        files = data.get("files", [])
        result = await asyncio.to_thread(process_rag_logic, files, question)
        return {"result": result}
    except Exception as exc:
        logger.exception("API Error")
        return JSONResponse(status_code=500, content={"error": "An internal error has occurred."})


@app.get("/documents")
async def api_documents():
    try:
        documents = await asyncio.to_thread(get_documents_logic)
        return {"documents": documents}
    except Exception:
        logger.exception("Documents API Error")
        return JSONResponse(status_code=500, content={"error": "An internal error has occurred."})


@app.get("/documents/{document_name:path}")
async def api_document_content(document_name: str):
    source = await asyncio.to_thread(get_document_source_logic, document_name)
    if not source:
        raise HTTPException(status_code=404, detail="Document not found")

    payload = await asyncio.to_thread(kb.get_document_bytes, document_name)
    if payload is None:
        raise HTTPException(status_code=404, detail="Document data not available")

    filename = document_name
    media_type = None
    if filename.lower().endswith(".pdf"):
        media_type = "application/pdf"
    elif filename.lower().endswith(".txt"):
        media_type = "text/plain; charset=utf-8"
    else:
        media_type = "application/octet-stream"

    return Response(
        content=payload,
        media_type=media_type,
        headers={"Content-Disposition": f'inline; filename="{filename}"'},
    )


# UI LOGIC
def refresh_indexed_docs_ui():
    docs = get_documents_logic()
    return gr.update(choices=docs, value=None), f"Indexed documents: {len(docs)}"


def show_selected_document_ui(selected_doc):
    if not selected_doc:
        return "No document selected.", "<p>Select a document to preview.</p>"

    source = kb.get_document_source(selected_doc)
    if not source:
        return f"Selected: {selected_doc}", "<p>Document source is not available.</p>"

    encoded = urllib.parse.quote(selected_doc, safe="")
    file_url = f"/documents/{encoded}"
    if selected_doc.lower().endswith(".pdf"):
        preview = (
            f'<p><a href="{file_url}" target="_blank" rel="noopener noreferrer">Open {html.escape(selected_doc)} in new tab</a></p>'
            f'<iframe src="{file_url}" style="width:100%;height:640px;border:1px solid #ddd;border-radius:6px;"></iframe>'
        )
        return f"Selected: {selected_doc}", preview

    if selected_doc.lower().endswith(".txt"):
        content = kb.read_text_document(selected_doc)
        if not content:
            return f"Selected: {selected_doc}", "<p>Could not read text preview.</p>"
        preview = (
            f'<p><a href="{file_url}" target="_blank" rel="noopener noreferrer">Open {html.escape(selected_doc)} in new tab</a></p>'
            f'<pre style="white-space:pre-wrap;word-wrap:break-word;max-height:640px;overflow:auto;border:1px solid #ddd;'
            f'border-radius:6px;padding:10px;background:#fafafa;">{html.escape(content)}</pre>'
        )
        return f"Selected: {selected_doc}", preview

    return f"Selected: {selected_doc}", f'<p><a href="{file_url}" target="_blank" rel="noopener noreferrer">Open file</a></p>'


def run_rag_ui(files, question):
    """
    Yields 3 values to match the Right Column:
    1. Question Display
    2. Scratchpad (Markdown)
    3. Final Answer (Textbox)
    """
    q_text = question.strip()
    if not q_text:
        yield "", "❌ Please ask a question.", ""
        return

    # 1. Build KB if files exist
    if files:
        yield q_text, "🔄 Processing files...", ""
        file_paths = [f.name for f in files]
        kb.build(file_paths)

    yield q_text, "🔄 Thinking...", ""

    scratchpad = ""
    final = ""

    # 2. Stream chunks
    for chunk in run_rag(q_text, kb):
        if "**Final Answer:**" in chunk:
            parts = chunk.split("**Final Answer:**")
            if parts[0].strip():
                scratchpad += parts[0].strip() + "\n\n"
            final = parts[1].strip()
        else:
            scratchpad += chunk

        yield q_text, scratchpad, final


def clear_all_ui():
    """Clears DB and resets all UI components"""
    kb.clear()
    return (
        None,
        "",
        "",
        "",
        "",
        gr.update(choices=[], value=None),
        "Indexed documents: 0",
        "No document selected.",
        "<p>Select a document to preview.</p>",
    )


# UI LAYOUT
with gr.Blocks(title=TITLE) as demo:

    gr.Markdown(f"# {TITLE}")

    with gr.Row(equal_height=False):
        with gr.Column(scale=1):
            gr.Markdown("### User Input & Controls")
            files_input = gr.File(label="Upload Documents", file_count="multiple")
            indexed_docs_status = gr.Markdown("Indexed documents: loading...")
            indexed_docs_dropdown = gr.Dropdown(
                label="Pre-populated / Indexed Documents",
                choices=[],
                value=None,
                multiselect=False,
                interactive=True,
            )
            refresh_docs_btn = gr.Button("Refresh Documents", variant="secondary")
            q_input = gr.Textbox(label="Ask a Question", lines=4, placeholder="Type here...")

            with gr.Row():
                clr_btn = gr.Button("Clear All", variant="secondary")
                sub_btn = gr.Button("Submit", variant="primary")

        with gr.Column(scale=2):
            gr.Markdown("### Reasoning & Final Answer")
            q_display = gr.Textbox(label="Question", interactive=False, lines=2)

            with gr.Accordion("Live Scratchpad", open=True):
                scratchpad_out = gr.Markdown(label="Step-by-Step Process")

            final_out = gr.Textbox(label="Final Answer", lines=8, interactive=False)
            selected_doc_status = gr.Markdown("No document selected.")
            document_preview = gr.HTML("<p>Select a document to preview.</p>")

    stream_event = sub_btn.click(
        fn=run_rag_ui,
        inputs=[files_input, q_input],
        outputs=[q_display, scratchpad_out, final_out],
        show_progress="full",
    )

    stream_event.then(fn=lambda: "", inputs=None, outputs=[q_input])
    stream_event.then(fn=refresh_indexed_docs_ui, inputs=None, outputs=[indexed_docs_dropdown, indexed_docs_status])

    clr_btn.click(
        fn=clear_all_ui,
        inputs=None,
        outputs=[
            files_input,
            q_input,
            q_display,
            scratchpad_out,
            final_out,
            indexed_docs_dropdown,
            indexed_docs_status,
            selected_doc_status,
            document_preview,
        ],
    )
    refresh_docs_btn.click(fn=refresh_indexed_docs_ui, inputs=None, outputs=[indexed_docs_dropdown, indexed_docs_status])
    indexed_docs_dropdown.change(
        fn=show_selected_document_ui,
        inputs=[indexed_docs_dropdown],
        outputs=[selected_doc_status, document_preview],
    )

    demo.load(fn=refresh_indexed_docs_ui, inputs=None, outputs=[indexed_docs_dropdown, indexed_docs_status])

app = gr.mount_gradio_app(app, demo, path="/")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=GRADIO_PORT)
