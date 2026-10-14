# cron:37 7 * * *
# new Env('烧饼论坛每日签到');
"""
烧饼论坛每日签到

环境变量：
- SB_COOKIE：论坛 Cookie
- SB_USER_AGENT：与该 Cookie 登录时一致的浏览器 User-Agent
"""
import base64
import hashlib
import itertools
import json
import os
import random
import re
import time
import zlib
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

import requests


SB_URL = "https://sb.sb"
SB_COOKIE = os.environ.get("SB_COOKIE", "")
SB_USER_AGENT = os.environ.get(
    "SB_USER_AGENT",
    (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/155.0.0.0 Safari/537.36"
    ),
)
TIMEOUT = 30
START_DELAY = (30, 300)
SUBMIT_DELAY = (3, 8)
REQUIRED_COOKIES = {"__Host-bbs_session"}
CHALLENGE_MARKERS = (
    "cf-chl-",
    "cf-browser-verification",
    "challenge-platform",
    "just a moment...",
    "enable javascript and cookies to continue",
)
CAP_FONT_WIDTHS = (
    1224.94, 1153.59, 1083.7, 1200.87, 1156.96, 1080.18, 1224.94, 1224.94, 1198.23,
    1224.94, 1224.94, 1224.94, 1203.86, 1224.94, 1224.94, 1224.94, 1224.94,
)
GREASE_CHARS = " (:-./);=?_"
GREASE_VERSIONS = ("8", "99", "24")
GREASE_ORDERS = ((0, 1, 2), (0, 2, 1), (1, 0, 2), (1, 2, 0), (2, 0, 1), (2, 1, 0))
INSTR_NONCE = re.compile(r'nonce:\s*"([0-9a-fA-F]+)"')
INSTR_VARS = re.compile(r"var (\w+)=(-?\d+);var (\w+)=(-?\d+);var (\w+)=(-?\d+);var (\w+)=(-?\d+);")
INSTR_CS_FN = re.compile(r"function (\w+)\(a,b,c\)\{function F\(d\)\{this\.v=function\(\)\{return this\.k\^d;")
INSTR_GM_FN = re.compile(r"function (\w+)\(x,y,z\)\{var d=document\.createElement\('div'\)")
INSTR_FINAL = re.compile(r"(\w+)\s*=\s*\(\(\s*\1\s*\^\s*\d+\s*\)\s*&\s*0x7FFFFFFF\s*\)[^;]*;")
INSTR_TERNARY = re.compile(r"navigator\.userAgent\s*\?\s*(\d+)\s*:\s*\d+")
JS_TOKEN = re.compile(r"\s*(?:(0[xX][0-9a-fA-F]+|\d+)|([A-Za-z_$][\w$]*)|(>>>|<<|>>|[~^&|+%(),]))")
JS_IDENTIFIER = re.compile(r"[A-Za-z_$][\w$]*")
JS_BINARY_LEVELS = (("|",), ("^",), ("&",), ("<<", ">>", ">>>"), ("+",), ("%",))


def normalize_text(value):
    """将页面局部文本规范化为单行内容。"""
    return " ".join(value.split())


def log_excerpt(value, limit=500):
    """限制诊断文本长度，避免异常页面污染日志。"""
    text = normalize_text(value)
    return text if len(text) <= limit else f"{text[:limit]}..."


class SigninPageParser(HTMLParser):
    """提取签到页面的表单、状态及结果节点。"""

    CAPTURES = {
        "streak": "signin-streak-num",
        "hero_main": "signin-hero-main",
    }

    def __init__(self):
        super().__init__()
        self.in_signin_form = False
        self.has_signin_form = False
        self.csrf_token = ""
        self.already_signed = False
        self.cap_endpoint = ""
        self.cap_field = "cap-token"
        self.hero_depth = 0
        self.result_depth = 0
        self.results = []
        self.depths = {name: 0 for name in self.CAPTURES}
        self.parts = {name: [] for name in self.CAPTURES}

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        classes = set(attributes.get("class", "").split())

        if attributes.get("data-cap-api-endpoint") and not self.cap_endpoint:
            self.cap_endpoint = attributes["data-cap-api-endpoint"]
            self.cap_field = attributes.get("data-cap-hidden-field-name") or "cap-token"

        if tag == "form":
            action = urlparse(attributes.get("action", "")).path.rstrip("/")
            method = attributes.get("method", "get").lower()
            self.in_signin_form = (
                "signin-form" in classes
                and action == "/checkin"
                and method == "post"
            )
            self.has_signin_form = self.has_signin_form or self.in_signin_form
        elif tag == "input" and self.in_signin_form:
            if attributes.get("name") == "_csrf":
                self.csrf_token = attributes.get("value", "")

        if tag == "div":
            if self.hero_depth:
                self.hero_depth += 1
            if self.result_depth:
                self.result_depth += 1
            for name, depth in self.depths.items():
                if depth:
                    self.depths[name] = depth + 1

            if not self.hero_depth and "signin-hero" in classes:
                self.hero_depth = 1
            if not self.result_depth and "signin-result" in classes:
                self.result_depth = 1
                self.results.append({"classes": classes, "parts": []})
            for name, class_name in self.CAPTURES.items():
                if not self.depths[name] and class_name in classes:
                    self.depths[name] = 1

        if (
            tag == "button"
            and self.hero_depth
            and "btn-post" in classes
            and "disabled" in attributes
        ):
            self.already_signed = True

    def handle_endtag(self, tag):
        if tag == "form":
            self.in_signin_form = False

        if tag == "div":
            if self.hero_depth:
                self.hero_depth -= 1
            if self.result_depth:
                self.result_depth -= 1
            for name, depth in self.depths.items():
                if depth:
                    self.depths[name] = depth - 1

    def handle_data(self, data):
        if self.result_depth:
            self.results[-1]["parts"].append(data)
        for name, depth in self.depths.items():
            if depth:
                self.parts[name].append(data)

    def text(self, name):
        return normalize_text(" ".join(self.parts[name]))

    def signin_results(self):
        return tuple(
            (result["classes"], normalize_text(" ".join(result["parts"])))
            for result in self.results
        )


def build_session(cookie):
    """创建携带论坛 Cookie 的请求会话。"""
    session = requests.Session()
    session.headers.update(
        {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Cookie": cookie,
            "User-Agent": SB_USER_AGENT,
        }
    )
    return session


def parse_signin_page(html):
    parser = SigninPageParser()
    parser.feed(html)
    parser.close()
    return parser


def missing_cookie_names(cookie):
    """检查签到所需 Cookie，仅返回缺失的字段名。"""
    names = {
        item.split("=", 1)[0].strip()
        for item in cookie.split(";")
        if "=" in item
    }
    return sorted(REQUIRED_COOKIES - names)


def wait_random_interval(delay_range, stage):
    """在指定阶段执行有界随机等待。"""
    delay = random.uniform(*delay_range)
    print(f"⏳ {stage}，等待 {delay:.1f} 秒")
    time.sleep(delay)


def build_result(
    status,
    message,
    *,
    days="",
    reward="",
    warnings=(),
    log_details=(),
):
    return {
        "success": status != "failed",
        "status": status,
        "message": message,
        "days": days,
        "reward": reward,
        "warnings": warnings,
        "log_details": log_details,
    }


def failure(message, detail):
    return build_result("failed", message, log_details=(detail,))


def parse_streak_days(page):
    """从固定的连续签到数字节点读取天数。"""
    streak = page.text("streak")
    if re.fullmatch(r"\d+", streak):
        return streak, None

    if streak:
        detail = (
            "连续签到天数解析失败：内容不是有效整数；"
            f"source=.signin-streak-num text={log_excerpt(streak)!r}"
        )
    else:
        detail = (
            "连续签到天数解析失败：未找到目标节点；"
            "source=.signin-streak-num context=.signin-hero-main "
            f"text={log_excerpt(page.text('hero_main'))!r}"
        )

    return "", ("连续签到天数解析失败", detail)


def parse_reward(result_text):
    """从签到成功提示中的“共 N 饼”读取最终奖励。"""
    rewards = re.findall(r"共\s*(\d+)\s*饼", result_text)
    if len(rewards) == 1:
        return rewards[0], None

    return "", (
        "本次获得烧饼数解析失败",
        (
            "本次获得烧饼数解析失败：未找到唯一的“共 N 饼”；"
            "source=.signin-result.success "
            f"text={log_excerpt(result_text)!r}"
        ),
    )


def parse_post_result(html):
    """仅依据 POST 响应中的结果节点判断签到是否成功。"""
    page = parse_signin_page(html)
    results = page.signin_results()
    if len(results) != 1:
        if results:
            nodes = "; ".join(
                (
                    f"#{index} class={' '.join(sorted(classes))!r} "
                    f"text={log_excerpt(text)!r}"
                )
                for index, (classes, text) in enumerate(results, 1)
            )
            detail = (
                "POST 未确认签到结果：.signin-result 节点数量异常；"
                f"count={len(results)} nodes=[{nodes}]"
            )
        else:
            detail = "POST 未确认签到成功：未找到 .signin-result"
            site_error = extract_site_error(html)
            if site_error:
                detail += f"；site_error={site_error!r}"
        return failure("签到失败", detail)

    result_classes, result_text = results[0]
    if "success" not in result_classes:
        detail = (
            "POST 未确认签到成功："
            f"result_class={' '.join(sorted(result_classes))!r} "
            f"result={log_excerpt(result_text)!r}"
        )
        return failure("签到失败", detail)

    days, days_warning = parse_streak_days(page)
    reward, reward_warning = parse_reward(result_text)
    warnings = tuple(item for item in (days_warning, reward_warning) if item)
    return build_result(
        "success",
        "签到成功",
        days=days,
        reward=reward,
        warnings=warnings,
    )


def validate_response(response, stage):
    """验证响应状态与来源；异常时返回分类结果。"""
    status = response.status_code
    site_error = extract_site_error(response.text) if status >= 400 else ""
    site_detail = f" site_error={site_error!r}" if site_error else ""
    if status in {401, 403, 429}:
        return failure(
            "访问受限，签到未完成",
            f"{stage}被拒绝：status={status} url={response.url!r}{site_detail}",
        )
    if status >= 500:
        return failure(
            "论坛服务异常，签到未完成",
            f"论坛服务异常：stage={stage} status={status} url={response.url!r}{site_detail}",
        )
    if status >= 400:
        return failure(
            "签到请求异常",
            f"请求异常：stage={stage} status={status} url={response.url!r}{site_detail}",
        )

    response_url = urlparse(response.url)
    expected_url = urlparse(SB_URL)
    if response_url.scheme != "https" or response_url.netloc != expected_url.netloc:
        return failure(
            "签到响应异常",
            f"响应跳转到非论坛域名：stage={stage} final_url={response.url!r}",
        )

    if response_url.path.rstrip("/") in {"/login", "/signin/login"}:
        return failure(
            "登录已失效，请更新 Cookie",
            f"登录失效：{stage}跳转到 {response_url.path}",
        )

    content_type = response.headers.get("Content-Type", "").lower()
    if "text/html" not in content_type:
        return failure(
            "签到响应异常",
            f"响应类型异常：stage={stage} content_type={content_type!r}",
        )

    html = response.text.lower()
    if any(marker in html for marker in CHALLENGE_MARKERS):
        return failure(
            "访问受限，签到未完成",
            f"{stage}遇到 Cloudflare 验证",
        )

    return None


class CapError(Exception):
    pass


def to_int32(value):
    return (int(value) + 0x80000000) % 0x100000000 - 0x80000000


def js_mod(left, right):
    if right == 0:
        raise CapError("表达式出现除以零")
    remainder = abs(left) % abs(right)
    return -remainder if left < 0 else remainder


JS_OPERATORS = {
    "|": lambda left, right: to_int32(left) | to_int32(right),
    "^": lambda left, right: to_int32(left) ^ to_int32(right),
    "&": lambda left, right: to_int32(left) & to_int32(right),
    "<<": lambda left, right: to_int32(to_int32(left) << (to_int32(right) & 31)),
    ">>": lambda left, right: to_int32(left) >> (to_int32(right) & 31),
    ">>>": lambda left, right: (to_int32(left) & 0xFFFFFFFF) >> (to_int32(right) & 31),
    "+": lambda left, right: left + right,
    "%": js_mod,
}


def tokenize_js(source):
    tokens = []
    position = 0
    source = source.strip()
    while position < len(source):
        match = JS_TOKEN.match(source, position)
        if not match:
            raise CapError(f"表达式无法解析：{log_excerpt(source)!r}")
        number, name, operator = match.groups()
        if number:
            tokens.append(("number", int(number, 16) if number[:2] in {"0x", "0X"} else int(number)))
        elif name:
            tokens.append(("name", name))
        else:
            tokens.append(("op", operator))
        position = match.end()
    return tokens


class JsExpression:
    def __init__(self, source, variables, functions):
        self.source = source
        self.tokens = tokenize_js(source)
        self.position = 0
        self.variables = variables
        self.functions = functions

    def evaluate(self):
        value = self.binary(0)
        if self.position != len(self.tokens):
            raise CapError(f"表达式无法解析：{log_excerpt(self.source)!r}")
        return value

    def peek(self):
        if self.position < len(self.tokens):
            return self.tokens[self.position]
        return (None, None)

    def take(self):
        token = self.peek()
        if token[0] is None:
            raise CapError(f"表达式意外结束：{log_excerpt(self.source)!r}")
        self.position += 1
        return token

    def expect(self, operator):
        if self.take() != ("op", operator):
            raise CapError(f"表达式缺少 {operator!r}：{log_excerpt(self.source)!r}")

    def binary(self, level):
        if level == len(JS_BINARY_LEVELS):
            return self.unary()
        value = self.binary(level + 1)
        while self.peek()[0] == "op" and self.peek()[1] in JS_BINARY_LEVELS[level]:
            operator = self.take()[1]
            value = JS_OPERATORS[operator](value, self.binary(level + 1))
        return value

    def unary(self):
        if self.peek() == ("op", "~"):
            self.take()
            return ~to_int32(self.unary())
        return self.primary()

    def primary(self):
        kind, value = self.take()
        if kind == "number":
            return value
        if kind == "op" and value == "(":
            result = self.binary(0)
            self.expect(")")
            return result
        if kind == "name" and self.peek() == ("op", "("):
            self.take()
            args = []
            while self.peek() != ("op", ")"):
                args.append(self.binary(0))
                if self.peek() == ("op", ","):
                    self.take()
            self.take()
            if value not in self.functions or len(args) != 3:
                raise CapError(f"未知函数调用：{value}({len(args)})")
            return self.functions[value](*args)
        if kind == "name" and value in self.variables:
            return self.variables[value]
        raise CapError(f"表达式无法解析：{log_excerpt(self.source)!r}")


def cs_mix(a, b, c):
    return (to_int32(b) ^ to_int32(a)) | (to_int32(c) ^ to_int32(b))


def gm_dom_compute(*values):
    total = 0
    for value in values:
        for _ in range(8):
            if to_int32(value) & 1 == 0:
                total += value
            value = to_int32(value) >> 1
    return js_mod(total, 256)


def eval_instr_state(script):
    initial = INSTR_VARS.search(script)
    cs_name = INSTR_CS_FN.search(script)
    gm_name = INSTR_GM_FN.search(script)
    if not initial or not cs_name or not gm_name:
        raise CapError("instrumentation 脚本结构无法识别：缺少 state 初值或运算函数")

    names = initial.group(1, 3, 5, 7)
    variables = {name: int(value) for name, value in zip(names, initial.group(2, 4, 6, 8))}
    start = re.search(rf"\b{re.escape(names[0])}\s*=\s*{re.escape(names[0])}\s*\^", script)
    finals = [match for match in INSTR_FINAL.finditer(script) if match.group(1) in variables]
    if not start or {match.group(1) for match in finals} != set(names):
        raise CapError("instrumentation 脚本结构无法识别：缺少 state 计算块")
    end = max(match.end() for match in finals)
    if end <= start.start():
        raise CapError("instrumentation 脚本结构无法识别：state 计算块顺序异常")

    functions = {cs_name.group(1): cs_mix, gm_name.group(1): gm_dom_compute}
    block = INSTR_TERNARY.sub(r"\1", script[start.start():end])
    for statement in filter(None, (item.strip() for item in block.split(";"))):
        name, separator, expression = statement.partition("=")
        name = name.strip()
        if not separator or not JS_IDENTIFIER.fullmatch(name):
            raise CapError(f"instrumentation 语句无法识别：{log_excerpt(statement)!r}")
        variables[name] = JsExpression(expression, variables, functions).evaluate()
    return {name: variables[name] for name in names}


def chrome_brands(major):
    grease = (
        f"Not{GREASE_CHARS[major % len(GREASE_CHARS)]}A"
        f"{GREASE_CHARS[(major + 1) % len(GREASE_CHARS)]}Brand/"
        f"{GREASE_VERSIONS[major % len(GREASE_VERSIONS)]}"
    )
    brands = [None] * 3
    order = GREASE_ORDERS[major % len(GREASE_ORDERS)]
    brands[order[0]] = grease
    brands[order[1]] = f"Chromium/{major}"
    brands[order[2]] = f"Google Chrome/{major}"
    return brands


def cap_fingerprint(user_agent):
    major = int(re.search(r"Chrome/(\d+)", user_agent).group(1))
    return {
        "webdriver": False,
        "pdfViewerEnabled": True,
        "tamper": {
            "getParameterWebGL": True,
            "toDataURL": True,
            "getImageData": True,
            "permissionsQuery": True,
            "fnToString": True,
        },
        "uaDataPresent": True,
        "outerWH": [2560, 1410],
        "isExtended": True,
        "productSub": "20030107",
        "screen": {"width": 2560, "height": 1440},
        "oscpu": "__undefined",
        "engine": {"hasMozInnerScreenX": False, "hasChrome": True},
        "fontWidths": list(CAP_FONT_WIDTHS),
        "plugins": {"length": 5},
        "uaData": {"mobile": False, "brands": chrome_brands(major)},
        "ua": user_agent,
        "deviceMemory": 32,
    }


def build_instr(encoded):
    try:
        script = zlib.decompressobj(-15).decompress(base64.b64decode(encoded)).decode()
    except (ValueError, zlib.error) as error:
        raise CapError(f"instrumentation 脚本解码失败：error={error!r}") from error
    nonce = INSTR_NONCE.search(script)
    if not nonce:
        raise CapError("instrumentation 脚本缺少 nonce")
    return {
        "i": nonce.group(1),
        "state": eval_instr_state(script),
        "p": cap_fingerprint(SB_USER_AGENT),
        "ts": int(time.time() * 1000),
    }


def cap_gen(seed, length):
    value = 2166136261
    for char in seed:
        value = to_int32(value) ^ ord(char)
        value += sum(to_int32(value << shift) for shift in (1, 4, 7, 8, 24))
    state = value & 0xFFFFFFFF
    output = ""
    while len(output) < length:
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        output += f"{state:08x}"
    return output[:length]


def solve_pow(salt, target):
    full, remainder = divmod(4 * len(target), 8)
    target_bytes = bytes.fromhex(target + "0" * (len(target) % 2))
    prefix = target_bytes[:full]
    mask = (0xFF << (8 - remainder)) & 0xFF
    base = hashlib.sha256(salt.encode())
    for nonce in itertools.count():
        digest = base.copy()
        digest.update(str(nonce).encode())
        value = digest.digest()
        if value[:full] == prefix and (
            not remainder or (value[full] ^ target_bytes[full]) & mask == 0
        ):
            return nonce


def solve_cap_pow(token, count, salt_length, difficulty):
    return [
        solve_pow(cap_gen(f"{token}{index}", salt_length), cap_gen(f"{token}{index}d", difficulty))
        for index in range(1, count + 1)
    ]


def cap_request(url, referer, payload=None):
    headers = {
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Origin": SB_URL,
        "Referer": referer,
        "User-Agent": SB_USER_AGENT,
    }
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload, separators=(",", ":"))
    response = requests.post(url, data=body, headers=headers, timeout=TIMEOUT)
    try:
        data = response.json()
    except ValueError:
        data = None
    if not isinstance(data, dict):
        raise CapError(
            f"响应解析失败：url={url!r} status={response.status_code} "
            f"body={log_excerpt(response.text, 200)!r}"
        )
    return data


def solve_captcha(endpoint, referer):
    challenge = cap_request(f"{endpoint}challenge", referer)
    if challenge.get("error"):
        raise CapError(f"取题失败：error={challenge['error']!r}")
    if challenge.get("format") == 2 or challenge.get("challenges"):
        raise CapError(f"验证协议已升级，脚本暂不支持：format={challenge.get('format')!r}")

    spec = challenge.get("challenge")
    token = challenge.get("token")
    if (
        not isinstance(spec, dict)
        or not isinstance(token, str)
        or not token
        or not all(isinstance(spec.get(key), int) and spec[key] > 0 for key in "csd")
    ):
        raise CapError(f"题目格式异常：keys={sorted(challenge)!r} challenge={spec!r}")

    payload = {
        "token": token,
        "solutions": solve_cap_pow(token, spec["c"], spec["s"], spec["d"]),
    }
    if challenge.get("instrumentation"):
        payload["instr"] = build_instr(challenge["instrumentation"])

    result = cap_request(f"{endpoint}redeem", referer, payload)
    if not result.get("success") or not result.get("token"):
        raise CapError(f"redeem 未通过：response={log_excerpt(json.dumps(result, ensure_ascii=False), 300)!r}")
    return result["token"]


def extract_site_error(html):
    if "出错了" not in html:
        return ""
    text = re.sub(r"(?is)<(script|style|title|noscript)\b[^>]*>.*?</\1>", " ", html)
    text = normalize_text(re.sub(r"<[^>]*>", " ", text))
    _, _, message = text.partition("出错了")
    return log_excerpt(message.split("回到首页", 1)[0], 120)


def sb_signin(cookie):
    """执行烧饼论坛签到。"""
    if not cookie:
        return failure(
            "配置异常，签到未执行",
            "配置异常：未设置 SB_COOKIE",
        )

    missing = missing_cookie_names(cookie)
    if missing:
        return failure(
            "配置异常，签到未执行",
            f"配置异常：Cookie 缺少必要字段：{', '.join(missing)}",
        )

    if not re.search(r"Chrome/\d+", SB_USER_AGENT):
        return failure(
            "配置异常，签到未执行",
            f"配置异常：SB_USER_AGENT 需为 Chrome UA：{SB_USER_AGENT!r}",
        )

    session = build_session(cookie)
    signin_url = f"{SB_URL}/checkin/"

    try:
        wait_random_interval(START_DELAY, "签到任务启动")
        response = session.get(signin_url, timeout=TIMEOUT)
        error = validate_response(response, "签到页面")
        if error:
            return error
        print("[INFO] GET 签到页面成功")

        page = parse_signin_page(response.text)
        if page.already_signed:
            print("[INFO] 检测到今日已签到，本次不发起 POST")
            return build_result("already_signed", "今日已签到")

        if not page.has_signin_form:
            results = page.signin_results()
            return failure(
                "签到页面结构异常",
                (
                    "GET 页面结构异常：未找到已签到状态或签到表单；"
                    f"result_count={len(results)} "
                    f"context={log_excerpt(page.text('hero_main'))!r}"
                ),
            )
        if not page.csrf_token:
            return failure(
                "签到页面结构异常",
                "GET 页面结构异常：签到表单缺少 _csrf",
            )
        print("[INFO] 找到签到表单和 CSRF token")

        form = {"_csrf": page.csrf_token, "message": ""}
        if page.cap_endpoint:
            endpoint = urljoin(signin_url, page.cap_endpoint).rstrip("/") + "/"
            started = time.monotonic()
            try:
                form[page.cap_field] = solve_captcha(endpoint, signin_url)
            except CapError as error:
                return failure(
                    "人机验证失败，签到未执行",
                    f"人机验证失败：endpoint={endpoint!r} {error}",
                )
            print(f"[INFO] 人机验证通过，耗时 {time.monotonic() - started:.1f} 秒")
        else:
            print("[INFO] 签到页面未要求人机验证")

        wait_random_interval(SUBMIT_DELAY, "提交签到前")
        response = session.post(
            signin_url,
            data=form,
            headers={"Origin": SB_URL, "Referer": signin_url},
            timeout=TIMEOUT,
        )
        error = validate_response(response, "签到提交")
        if error:
            return error
        print("[INFO] POST 签到请求成功")
        return parse_post_result(response.text)
    except requests.RequestException as error:
        return failure(
            "网络异常，签到未完成",
            f"网络异常：error={error!r}",
        )


def build_notification(result, executed_at):
    """生成面向 Telegram 的简洁通知。"""
    if result["status"] == "already_signed":
        lines = ["☑️ 今日已签到"]
    elif result["status"] == "success":
        lines = ["✅ 签到成功"]
        if result["reward"]:
            lines[0] += f"，获得 {result['reward']} 饼"
        if result["days"]:
            lines.append(f"📅 连续签到：{result['days']} 天")
        lines.extend(f"⚠️ {message}" for message, _ in result["warnings"])
    else:
        lines = [f"❌ {result['message']}"]

    lines.append(f"⏰ 执行时间：{executed_at}")
    return "\n".join(lines)


def log_result(result):
    """输出仅供诊断的详细日志。"""
    level = "INFO" if result["success"] else "ERROR"
    print(f"[{level}] 签到结果：{result['message']}")
    for detail in result["log_details"]:
        print(f"[ERROR] {detail}")
    for _, detail in result["warnings"]:
        print(f"[WARN] {detail}")


def message_push(title, message):
    """调用青龙系统通知。"""

    try:
        response = QLAPI.systemNotify({"title": title, "content": message})
        if response.get("code", 400) == 200:
            print("[INFO] Telegram 通知推送成功")
        else:
            print(f"[ERROR] Telegram 通知推送失败：response={response!r}")
    except Exception as error:
        print(f"[ERROR] Telegram 通知推送异常：error={error!r}")


def main():
    print("🚀 烧饼论坛签到脚本启动")
    result = sb_signin(SB_COOKIE)
    log_result(result)
    executed_at = time.strftime("%Y-%m-%d %H:%M:%S")
    content = build_notification(result, executed_at)
    message_push("烧饼论坛签到", content)


if __name__ == "__main__":
    main()
