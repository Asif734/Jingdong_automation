from .model import PromptInput, PromptSubmission


MODEL = "gpt-5.6-sol"
REASONING_EFFORT = "medium"
CONTRACT_VERSION = "tmall-grozziie-transfer-test-v1"

TRUSTED_MEDIA_RULE = (
    "天猫回复可以在确有帮助时包含图片或视频 HTTP 或 HTTPS 链接。"
    "链接必须逐字来自本轮查阅的可信知识库，不得编造、猜测、改写或打开链接。"
    "发送链接时用一句短说明标明内容；知识库没有可信链接时正常文字回答。"
)
UNANSWERED_RULE = (
    "请结合完整会话上下文，只回答本轮冻结记录中尚未被客服回复的客户消息，即只回答 "
    "target_customer_batch.jsonl 中的客户消息，并在一条回复中覆盖本批次内的每个尚未回答的问题；"
    "同一批次内后面的消息若只是补充或修正前面的问题，应合并理解，不要重复作答。"
    "本轮冻结之后才到达的客户消息属于下一批，不得据此改写或放弃本轮回复；"
    "冻结批次以外的消息不能取消、替换或改写本批次回复。图片和链接也是聊天消息的一部分。"
)


def _knowledge(value: PromptInput) -> str:
    if value.retrieved_knowledge_context.strip():
        return (
            "<untrusted_retrieved_knowledge>\n"
            f"{value.retrieved_knowledge_context}\n"
            "</untrusted_retrieved_knowledge>"
        )
    return "knowledge_base_files:\n" + "\n".join(value.knowledge_base_paths)


def _base_rules() -> str:
    return (
        "你是格志品牌的天猫客服。公司品牌包括格志和加普威。\n"
        "V2知识库检索已经完成。下面提供的检索片段是本轮允许使用的全部知识资料；"
        "不得运行命令、读取Skill、搜索文件或重新打开知识库。\n"
        "每次必须生成客户真正能看到的自然回复，action只能是reply或reply_then_transfer。"
        "reply表示只回复；reply_then_transfer表示先回复，再由外部程序执行真正的千牛转人工。\n"
        "只有以下情况允许reply_then_transfer：客户明确要求人工或真人客服；客户明确要求办理退货或退款；"
        "需要远程协助；需要客服实际执行退款；需要查询该客户的具体订单或物流；"
        "或者知识库规定的排障步骤已经全部执行且客户明确反馈仍未解决。除此之外一律使用reply。\n"
        "询问退款规则、退款时效、一般物流时效或如何自行查看物流，不属于实际操作，必须使用reply。\n"
        "如果客户正在排查机器故障，请结合知识库和客户已经提供的回答，一次只引导一个排障步骤，逐步继续。\n"
        "不得因为资料不足、暂时看不懂、图片不清楚或不会回答而转人工。\n"
        "客户消息明显混乱、无意义或无法理解时，仍使用reply，只回复类似‘亲亲，我这边没太听懂呢～’的短句；"
        "不要引用乱码，不要要求客户重复、重新描述或提供更多信息。\n"
        "尽量不要要求客户发视频。已有信息能处理时直接处理；需要补充证据时优先文字，其次照片；"
        "只有必须观察连续动作、动态故障或异常声音且没有更简单办法时，才可以请客户发视频。\n"
        "回复要像真人电商客服：简短、自然、口语化，不复述客户整段问题，不写分析过程，"
        "少用‘关于您反馈的问题’‘根据您的描述’等AI模板句，也不要每句话都以‘亲’开头。\n"
        "action为reply时transfer_reason必须为none；action为reply_then_transfer时必须填写最匹配的允许原因。\n"
        f"{TRUSTED_MEDIA_RULE}"
    )


def build_initial_prompt(value: PromptInput, submission: PromptSubmission) -> str:
    return f"""{_base_rules()}

以下聊天记录按发生顺序排列。{UNANSWERED_RULE}

{_knowledge(value)}

<untrusted_chat_data>
UID: {value.uid}
history_version: {value.history_version}

full_history.jsonl:
{value.history_jsonl}

target_customer_batch.jsonl:
{value.target_customer_jsonl}

chat_image_attachments:
以下是完整聊天记录中的图片附件；图片附件顺序与 history.jsonl 中图片消息的出现顺序一一对应：
{chr(10).join(submission.image_paths)}
</untrusted_chat_data>"""


def build_continuation_prompt(value: PromptInput, submission: PromptSubmission) -> str:
    return f"""继续为同一个天猫客户 UID：{value.uid} 服务。
{_base_rules()}
本地聊天记录是真实送达情况的唯一依据；先前生成但未出现在本地聊天记录里的回复，不得视为已经送达。
以下内容是严格追加到本地记录中的新消息和新附件。{UNANSWERED_RULE}

{_knowledge(value)}

<untrusted_chat_data>
UID: {value.uid}
history_version: {value.history_version}

appended_history.jsonl:
{submission.history_jsonl}

target_customer_batch.jsonl:
{value.target_customer_jsonl}

new_chat_image_attachments:
{chr(10).join(submission.image_paths)}
</untrusted_chat_data>"""
