import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from 'react'

export type Lang = 'en' | 'zh'
export type Part = string | { em: string }

const en = {
  meta: {
    title: 'AfterRay — Total recall. Zero upload.',
    htmlLang: 'en',
  },
  nav: {
    features: 'Features',
    skills: 'Skills',
    privacy: 'Privacy',
    download: 'Download',
  },
  hero: {
    eyebrow: 'AFTERRAY — LOCAL-FIRST AI MEMORY',
    titleA: ['Total ', { em: 'recall.' }] as Part[],
    titleB: [{ em: 'Zero' }, ' upload.'] as Part[],
    sub: 'AfterRay records what you see and hear on your Mac, and turns it into memory you can rewind, search, and build on — with AI that runs entirely on-device. No cloud. No account. No exceptions.',
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'See what it remembers',
    scroll: 'SCROLL',
    scrollHint: 'past the event horizon',
  },
  privacy: {
    eyebrow: 'PRIVACY BY ARCHITECTURE',
    statementA: ' bytes',
    statementB: 'leave your Mac.',
    sub: "Most AI memory products upload your life to someone else's server. AfterRay refuses by architecture: captures, indexes, model inputs, and model outputs stay on this machine.",
    pillars: [
      {
        title: 'Captured locally',
        body: 'Screen, system audio, microphone, and Accessibility semantics are written to an encrypted vault on your Mac.',
      },
      {
        title: 'Indexed locally',
        body: 'OCR, speech recognition, and semantic embeddings run on-device. Raw content and vectors never leave it.',
      },
      {
        title: 'Modeled locally',
        body: 'Summaries and answers come from a model running on your machine — a built-in GGUF or your own Ollama.',
      },
      {
        title: 'Encrypted at rest',
        body: 'SQLCipher + XChaCha20-Poly1305 encrypt every record. The key lives only in the macOS Keychain.',
      },
    ],
  },
  rewind: {
    eyebrow: '01 — REWIND · REWIND HISTORY',
    titleA: ['From one second,'] as Part[],
    titleB: ['to ', { em: 'one month.' }] as Part[],
    body: "The main surface isn't a search box — it's a zoomable timeline with a sense of spectacle. Scrub from a single second out to a day, a week, a month, and land back on the exact screen, conversation, and sound of that moment.",
    points: [
      'Continuous zoom: second → hour → day → month',
      'The screen and window structure at any instant',
      'Ambient and meeting audio, replayed in place',
    ],
    mock: {
      bar: 'RECALL — today',
      cards: [
        { time: '13:42', text: 'docs/afterray-v1-spec.md — editing' },
        { time: '13:37', text: 'Zoom · design review (recording 24:10)' },
        { time: '13:15', text: 'GitHub · PR #128 retention discussion' },
      ],
    },
  },
  search: {
    eyebrow: '02 — RECALL · SEARCH HISTORY',
    titleA: ['Half-remember it.'] as Part[],
    titleB: ['Find it ', { em: 'exactly.' }] as Part[],
    body: 'Forget the filename, forget the app. Full-text search plus on-device semantic embeddings take any word, concept, or half-remembered sentence and jump straight to the screen and audio evidence of that moment.',
    points: [
      'Joint search across OCR text and transcripts',
      'Semantic search: by meaning, not just keywords',
      'Every result replays the original evidence',
    ],
    mock: {
      query: 'that retention ceiling discussion',
      meta: 'full-text + semantic embedding · on-device index · 3 results',
      results: [
        {
          app: 'GitHub',
          time: 'Wed 13:15',
          text: '…retention ceiling for non-favorites — AFTERRAY_MAX_UNSTARRED_MOMENTS…',
          score: '0.91',
        },
        {
          app: 'Zoom',
          time: 'Wed 11:02',
          text: '"retention should be bounded by disk budget, not item count" — meeting transcript',
          score: '0.87',
        },
        {
          app: 'Notes',
          time: 'Tue 17:48',
          text: 'todo: switch retention to a GB budget, 10/20GB tiers',
          score: '0.82',
        },
      ],
    },
  },
  summary: {
    eyebrow: '03 — REFLECT · HOURLY DIGEST',
    titleA: ['Every hour,'] as Part[],
    titleB: ['already ', { em: 'written up.' }] as Part[],
    body: "The on-device model reads your history and compresses each hour into a few lines: what happened, what was decided, what's next. No more 5pm archaeology of your own day — and the inference never leaves your Mac.",
    points: [
      'Hourly, daily, and weekly granularities',
      'Every claim links back to replayable evidence',
      'Built-in model or your own Ollama, switch anytime',
    ],
    mock: {
      bar: 'HOURLY DIGEST — today',
      hours: [
        {
          span: '14:00 — 15:00',
          title: 'Closing out the disk chapter of the v1 spec',
          points: [
            'Finalized the 10/20GB disk budgets',
            'Replied to three retention comments on PR #128',
            '25-min design review: timeline zoom interaction confirmed',
          ],
          active: true,
        },
        {
          span: '15:00 — 16:00',
          title: 'Debugging the GOP encoder memory spike',
          points: [
            'Benchmarked HEIF vs JPEG decode paths',
            'Traced the spike to a duplicate copy in cold-still packing',
            'Read 4 docs on AV1 closed-GOP encoding',
          ],
          active: false,
        },
        {
          span: '16:00 — 17:00',
          title: 'Gaps: reading + replies',
          points: [
            'Finished two local-first architecture articles',
            'Replied to 9 iMessage / email threads',
            'Tomorrow: write the vault locking test first',
          ],
          active: false,
        },
      ],
    },
  },
  skills: {
    eyebrow: '04 — GROW · SKILL PROFILE',
    titleA: ['Your history,'] as Part[],
    titleB: ['distilled into ', { em: 'skills.' }] as Part[],
    sub: "The skills on your résumé are self-reported. AfterRay's grow out of your actual workflow: the local model reads your screen and conversation history, extracts the skills you really use, and suggests the next one worth building. All analysis stays on-device.",
    extractedLabel: 'EXTRACTED — from your history',
    suggestedLabel: 'SUGGESTED — the next one',
    extracted: [
      { name: 'React performance tuning', level: 'deep use', hours: '6.5h this week', evidence: '34 related screen sessions' },
      { name: 'Rust async debugging', level: 'proficient', hours: '4.2h this week', evidence: 'tokio logs × 12 sessions' },
      { name: 'Technical writing', level: 'steady output', hours: '3.1h this week', evidence: 'spec docs × 2, PR comments × 19' },
    ],
    suggested: [
      {
        name: 'AV1 encoding pipeline',
        tag: 'worth learning',
        why: 'You re-read closed-GOP docs across 3 sessions — a systematic pass would make the next one much faster.',
      },
      {
        name: 'SQLCipher key rotation',
        tag: 'worth deepening',
        why: 'Your vault design doc mentions key hierarchy repeatedly, but it has not landed in an experiment yet.',
      },
    ],
    note: '* Every suggestion is grounded in replayable local evidence, not a cloud profile.',
  },
  specs: {
    eyebrow: 'HOW IT WORKS',
    title: ['One pipeline, ', { em: 'entirely local.' }] as Part[],
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['Platform', 'macOS 15+ · Apple Silicon (M3 recommended)'],
      ['Storage', 'SQLCipher + XChaCha20-Poly1305, key in the Keychain'],
      ['Models', 'On-device ASR / Embedding / LLM, or your own Ollama'],
      ['Upload', 'None. No account, no telemetry, no cloud sync'],
    ],
  },
  final: {
    eyebrow: 'AFTERRAY',
    titleA: ['Give your Mac'] as Part[],
    titleB: ['a memory that ', { em: 'never forgets.' }] as Part[],
    sub: 'Free download · Runs locally · Your data stays yours',
    ctaPrimary: 'Download for macOS',
    ctaSecondary: 'GitHub',
  },
  footer: {
    tagline: 'A ray that persists after the day is gone.',
    rights: '© 2026 · Local-first · Private by design',
  },
}

export type Copy = typeof en

const zh: Copy = {
  meta: {
    title: 'AfterRay — 记住一切，止于本机',
    htmlLang: 'zh-CN',
  },
  nav: {
    features: '功能',
    skills: '技能',
    privacy: '隐私',
    download: '下载',
  },
  hero: {
    eyebrow: 'AFTERRAY — LOCAL-FIRST AI MEMORY',
    titleA: ['记住', { em: '一切。' }],
    titleB: ['止于', { em: '本机。' }],
    sub: 'AfterRay 持续记录你在 Mac 上看到与听到的一切，由完全在本机运行的 AI 整理成可回溯、可检索、可沉淀的记忆。无云端，无账号，无例外。',
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: '看看它记得什么',
    scroll: 'SCROLL',
    scrollHint: '越过事件视界',
  },
  privacy: {
    eyebrow: 'PRIVACY BY ARCHITECTURE',
    statementA: ' 字节',
    statementB: '离开你的 Mac。',
    sub: '大多数「AI 记忆」产品把你的生活上传到别人的服务器。AfterRay 从架构上拒绝这件事：数据、索引、模型输入、模型输出，全程留在本机。',
    pillars: [
      {
        title: '捕获在本地',
        body: '屏幕、系统音频、麦克风与 Accessibility 语义，全部写入你 Mac 上的加密 Vault。',
      },
      {
        title: '索引在本地',
        body: 'OCR、语音识别与语义 embedding 都在本机完成，原文与向量不出设备。',
      },
      {
        title: '模型在本地',
        body: '总结与问答由本机运行的大模型完成——内置 GGUF 或你自己的 Ollama。',
      },
      {
        title: '存储已加密',
        body: 'SQLCipher + XChaCha20-Poly1305 逐条加密，密钥只存在于 macOS Keychain。',
      },
    ],
  },
  rewind: {
    eyebrow: '01 — REWIND · 回溯历史',
    titleA: ['从一秒，'],
    titleB: ['缩放到', { em: '一个月。' }],
    body: '主入口不是搜索框，而是一条有「视觉奇观」感的可缩放时间线。拖动、缩放，从某一秒连续拉到一整天、一周、一个月——回到当时的屏幕、对话与上下文。',
    points: [
      '秒 / 小时 / 天 / 月连续缩放',
      '任意时刻的屏幕截图与窗口结构',
      '当时的环境音与会议录音回放',
    ],
    mock: {
      bar: 'RECALL — 今天',
      cards: [
        { time: '13:42', text: 'docs/afterray-v1-spec.md — 编辑中' },
        { time: '13:37', text: 'Zoom · 设计评审（录音 24:10）' },
        { time: '13:15', text: 'GitHub · PR #128 retention 策略讨论' },
      ],
    },
  },
  search: {
    eyebrow: '02 — RECALL · 检索历史',
    titleA: ['只记得大概，'],
    titleB: ['也能找回', { em: '确切。' }],
    body: '不记得文件名，不记得在哪个 App——没关系。全文检索叠加本地语义 embedding，用你记住的任何一个词、一个概念，甚至一句别人说过的话，直接跳回那一刻的屏幕与音频证据。',
    points: [
      'OCR 全文 + 语音转写联合检索',
      '语义搜索：按「意思」而不只是关键字',
      '每条结果都可回放原始证据',
    ],
    mock: {
      query: 'retention 上限那次讨论',
      meta: '全文 + 语义 embedding · 本机索引 · 3 条证据',
      results: [
        {
          app: 'GitHub',
          time: '周三 13:15',
          text: '…retention ceiling for non-favorites — AFTERRAY_MAX_UNSTARRED_MOMENTS…',
          score: '0.91',
        },
        {
          app: 'Zoom',
          time: '周三 11:02',
          text: '「保留策略这块我们按磁盘上限来，不按条数」—— 会议语音转写',
          score: '0.87',
        },
        {
          app: 'Notes',
          time: '周二 17:48',
          text: 'todo: 把 retention 改成按 GB 预算，10/20GB 两档',
          score: '0.82',
        },
      ],
    },
  },
  summary: {
    eyebrow: '03 — REFLECT · 每小时总结',
    titleA: ['每个小时，'],
    titleB: ['一段', { em: '写好的' }, '总结。'],
    body: '本地大模型持续阅读你的历史，把每个小时压成几行：做了什么、定了什么、下一步是什么。下午五点不用再回想「我今天到底干了啥」——推理全部发生在你的 Mac 上。',
    points: [
      '按小时 / 按天 / 按周三个粒度',
      '每条结论都附可回放的证据引用',
      '内置模型或你自己的 Ollama，随时切换',
    ],
    mock: {
      bar: 'HOURLY DIGEST — 今天',
      hours: [
        {
          span: '14:00 — 15:00',
          title: '收尾 v1 spec 的磁盘章节',
          points: [
            '定稿 10/20GB 两档磁盘预算',
            '在 PR #128 回复了三条 retention 评论',
            '25 分钟设计评审：确认时间线缩放交互',
          ],
          active: true,
        },
        {
          span: '15:00 — 16:00',
          title: '调试 GOP 编码的内存峰值',
          points: [
            'bench-codec 跑分对比 HEIF / JPEG',
            '定位到 cold-still 打包的重复拷贝',
            '查了 4 篇 AV1 closed-GOP 文档',
          ],
          active: false,
        },
        {
          span: '16:00 — 17:00',
          title: '碎片时间：阅读 + 沟通',
          points: [
            '读完两篇 local-first 架构文章',
            '回复 iMessage / 邮件共 9 条',
            '明天待办：先写 vault 锁定测试',
          ],
          active: false,
        },
      ],
    },
  },
  skills: {
    eyebrow: '04 — GROW · 技能画像',
    titleA: ['AI 读过你的历史，'],
    titleB: ['提炼出你的 ', { em: 'Skills。' }],
    sub: '简历上的技能是自己写的，AfterRay 的技能是从你真实的工作流里长出来的。本地模型阅读你的屏幕与对话历史，提炼出你真正在用的技能画像，并建议值得补强的下一个 skill。分析全程在本机完成。',
    extractedLabel: 'EXTRACTED — 从历史提炼',
    suggestedLabel: 'SUGGESTED — 建议的下一个',
    extracted: [
      { name: 'React 性能调优', level: '深度使用', hours: '本周 6.5h', evidence: '34 次相关屏幕活动' },
      { name: 'Rust 异步调试', level: '熟练', hours: '本周 4.2h', evidence: 'tokio 日志 × 12 段会话' },
      { name: '技术写作', level: '持续输出', hours: '本周 3.1h', evidence: 'spec 文档 × 2，PR 评论 × 19' },
    ],
    suggested: [
      {
        name: 'AV1 编码流水线',
        tag: '建议学习',
        why: '你在 3 个会话里反复查 closed-GOP 文档——系统化的理解会让下次快得多。',
      },
      {
        name: 'SQLCipher 密钥轮换',
        tag: '建议深入',
        why: '你的 vault 设计文档多次提到 key hierarchy，但还没有落到实验。',
      },
    ],
    note: '* 每条建议都基于可回放的本地证据，而非云端画像。',
  },
  specs: {
    eyebrow: 'HOW IT WORKS',
    title: ['一条', { em: '全程本地' }, '的流水线'],
    steps: ['Capture', 'OCR / ASR', 'Embedding', 'Encrypted Vault', 'Local LLM', 'Recall'],
    rows: [
      ['平台', 'macOS 15+ · Apple Silicon（推荐 M3）'],
      ['存储', 'SQLCipher + XChaCha20-Poly1305，密钥存于 Keychain'],
      ['模型', '本机 ASR / Embedding / LLM，或你自己的 Ollama'],
      ['上传', '无。没有账号，没有遥测，没有云端同步'],
    ],
  },
  final: {
    eyebrow: 'AFTERRAY',
    titleA: ['让你的 Mac'],
    titleB: ['拥有', { em: '不会遗忘' }, '的记忆。'],
    sub: '免费下载 · 本地运行 · 你的数据永远只是你的',
    ctaPrimary: '下载 macOS 版',
    ctaSecondary: 'GitHub',
  },
  footer: {
    tagline: 'A ray that persists after the day is gone.',
    rights: '© 2026 · 纯本地 · 纯隐私',
  },
}

export const copy: Record<Lang, Copy> = { en, zh }

const LangCtx = createContext<{ lang: Lang; setLang: (l: Lang) => void }>({
  lang: 'en',
  setLang: () => {},
})

const STORAGE_KEY = 'afterray-lang'

function detectLang(): Lang {
  try {
    const param = new URLSearchParams(window.location.search).get('lang')
    if (param === 'en' || param === 'zh') return param
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved === 'en' || saved === 'zh') return saved
  } catch {
    /* private mode etc. */
  }
  return navigator.language?.toLowerCase().startsWith('zh') ? 'zh' : 'en'
}

export function LangProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(detectLang)

  useEffect(() => {
    document.documentElement.lang = copy[lang].meta.htmlLang
    document.title = copy[lang].meta.title
    try {
      localStorage.setItem(STORAGE_KEY, lang)
    } catch {
      /* ignore */
    }
  }, [lang])

  return (
    <LangCtx.Provider value={{ lang, setLang: setLangState }}>
      {children}
    </LangCtx.Provider>
  )
}

export function useLang() {
  return useContext(LangCtx)
}

export function useCopy(): Copy {
  return copy[useLang().lang]
}

/** Renders title part arrays, wrapping { em } segments in <em>. */
export function Rich({ parts }: { parts: Part[] }) {
  return (
    <>
      {parts.map((p, i) =>
        typeof p === 'string' ? (
          <span key={i}>{p}</span>
        ) : p.em ? (
          <em key={i}>{p.em}</em>
        ) : null,
      )}
    </>
  )
}
