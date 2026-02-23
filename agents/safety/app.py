import logging
from datetime import datetime

import baker.logs
import baker.tools
from baker.agent import BakerAgent
from baker.settings import BakerSettings
from baker.prompt import read_instructions_from_file
from baker.tools.executor import execute_tool
import baker.tools.inventory.csv as inventory_csv
import baker.tools.orders.messages as orders_messages
import baker.tools.menu.renderer as menu_renderer
import os

import streamlit as st
from llama_stack_client import LlamaStackClient

# =============================================================================
# Logging Setup
# =============================================================================

log = logging.getLogger("baker")

# =============================================================================
# Agent Setup
# =============================================================================


def get_agent():
    """Create and cache the BakerAgent instance."""
    settings = BakerSettings()
    client = LlamaStackClient(base_url=settings.llama_stack_url)
    instructions = read_instructions_from_file(settings.prompt_file)

    return BakerAgent(
        model=settings.model_name,
        instructions=instructions,
        client=client,
        tools=baker.tools.TOOLS,
        tool_executor=execute_tool,
    )

# Trigger shield registration in the agent
get_agent()


# =============================================================================
# Streamlit App
# =============================================================================

st.set_page_config(
    page_title="Kernel and Crust - Baker Assistant",
    page_icon="🥐",
    layout="wide",
)

st.title("🥐 Kernel and Crust")
st.caption(
    "AI-powered bakery management for the Kernel and Crust bakery: plan the menu, handle customer pick-up orders, and manage the inventory."
)
st.caption(
    "The bakery menu is generated daily based on a no-waste approach and the inventory available."
)

# Initialize session state
if "messages" not in st.session_state:
    st.session_state.messages = [
        {
            "role": "assistant",
            "content": "Hi, I'm your bakery assistant. How can I help you today?",
        }
    ]
if "previous_response_id" not in st.session_state:
    st.session_state.previous_response_id = None

# Two-column layout
col_left, col_right = st.columns([2, 1])


# =============================================================================
# Left Column: Chat Panel
# =============================================================================
with col_left:
    chat_container = st.container(height=500)

    with chat_container:
        for message in st.session_state.messages:
            if "tool_calls" in message and message["tool_calls"]:
                for tc in message["tool_calls"]:
                    with st.chat_message("assistant"):
                        st.markdown(
                            f":blue-badge[**Tool call**: `{tc['name']}({tc['arguments']})`]",
                            help="",
                        )
                        # st.code(f"{tc['name']}({tc['arguments']})", language="python")

            with st.chat_message(message["role"]):
                st.markdown(message["content"])

    prompt = st.chat_input("Ask about inventory, orders, or menu planning...")
    if prompt:
        st.session_state.messages.append({"role": "user", "content": prompt})

        with chat_container:
            with st.chat_message("user"):
                st.markdown(prompt)

            with st.chat_message("assistant"):
                with st.spinner(":gray[_Thinking..._]"):
                    try:
                        agent = get_agent()
                        response_text, response_id, tool_calls = agent.send_message(
                            prompt, st.session_state.previous_response_id
                        )
                        st.session_state.previous_response_id = response_id

                        st.markdown(response_text)

                        if tool_calls:
                            with st.expander("🔧 Tools used"):
                                for tc in tool_calls:
                                    st.code(
                                        f"{tc['name']}({tc['arguments']})",
                                        language="python",
                                    )

                    except Exception as e:
                        log.exception(f"Error while connecting to the LLM: {e}")
                        response_text = f"Sorry, I encountered an error: {e}"
                        tool_calls = []
                        st.error(response_text)

        st.session_state.messages.append(
            {"role": "assistant", "content": response_text, "tool_calls": tool_calls}
        )
        st.rerun()


# =============================================================================
# Right Column: Inventory, Orders & Menu (Tabs)
# =============================================================================
with col_right:
    tab_inventory, tab_orders, tab_menu = st.tabs(
        [":egg: Inventory", ":takeout_box: Pick-up Orders", ":cake: Today's Menu"]
    )

    # -------------------------------------------------------------------------
    # Inventory Tab
    # -------------------------------------------------------------------------
    with tab_inventory:
        inv_data = inventory_csv.get_inventory()
        today = datetime.now().date()

        # Build table data
        table_rows = []
        for product, info in inv_data.items():
            qty = float(info["quantity"]) if info["quantity"] else 0

            # Determine status
            status = ""
            if qty == 0:
                status = "🔴"
            elif info["expiry_date"]:
                try:
                    expiry = datetime.strptime(info["expiry_date"], "%Y-%m-%d").date()
                    if (expiry - today).days <= 2:
                        status = "🟡"
                except ValueError:
                    pass
            if not status and info["received_date"]:
                try:
                    received = datetime.strptime(
                        info["received_date"], "%Y-%m-%d"
                    ).date()
                    if (today - received).days <= 1:
                        status = "🟢"
                except ValueError:
                    pass

            # Format expiry date
            expiry_str = ""
            if info["expiry_date"]:
                try:
                    exp = datetime.strptime(info["expiry_date"], "%Y-%m-%d")
                    expiry_str = exp.strftime("%b %d")
                except ValueError:
                    pass

            table_rows.append(
                {
                    "": status,
                    "Item": info["name"],
                    "Qty": f"{info['quantity']} {info['unit']}",
                    "Expires": expiry_str,
                    "Notes": info["notes"] or "",
                }
            )

        # Display as scrollable dataframe
        st.dataframe(
            table_rows,
            width="content",
            height=400,
            hide_index=True,
        )
        st.caption("🟢 Fresh  🟡 Expiring  🔴 Out of stock")

    # -------------------------------------------------------------------------
    # Orders Tab
    # -------------------------------------------------------------------------
    with tab_orders:
        customers = orders_messages.get_customer_orders()

        if customers:
            for customer in customers:
                with st.expander(f"**{customer['customer']}**"):
                    for entry in customer["conversation"]:
                        role_icon = "👤" if entry["role"] == "customer" else "🧑‍🍳"
                        st.markdown(f"{role_icon} {entry['content']}")
                        st.caption(
                            f"{entry['timestamp'].strftime('%Y-%m-%d %H:%M:%S')}"
                        )
        else:
            st.info("No pickup orders yet.")

    # -------------------------------------------------------------------------
    # Menu Tab
    # -------------------------------------------------------------------------
    with tab_menu:
        if os.path.exists(menu_renderer.pdf):
            # Show the styled HTML preview
            st.pdf(menu_renderer.pdf)

            # Download button for the PDF
            with open(menu_renderer.pdf, "rb") as pdf_file:
                st.download_button(
                    label="Download PDF",
                    data=pdf_file,
                    file_name=menu_renderer.pdf,
                    mime="application/pdf",
                )
        else:
            st.info("No menu generated yet. Ask the assistant to create one!")
