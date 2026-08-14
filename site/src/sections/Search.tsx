import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function Search() {
  const t = useCopy().search
  return (
    <section className="section feature feature-flip">
      <Reveal className="feature-mock" delay={150}>
        <div className="mock search-mock">
          <div className="search-box">
            <span className="search-icon">⌕</span>
            <span className="search-query">{t.mock.query}</span>
            <span className="search-caret" />
          </div>
          <div className="search-meta mono dim">{t.mock.meta}</div>
          {t.mock.results.map((r) => (
            <div key={r.time} className="search-result">
              <div className="sr-head">
                <span className="sr-app">{r.app}</span>
                <span className="mono dim">{r.time}</span>
                <span className="mono accent sr-score">{r.score}</span>
              </div>
              <p className="sr-text">{r.text}</p>
            </div>
          ))}
        </div>
      </Reveal>
      <div className="feature-text">
        <Reveal>
          <p className="eyebrow mono">{t.eyebrow}</p>
          <h2 className="feature-title">
            <Rich parts={t.titleA} />
            <br />
            <Rich parts={t.titleB} />
          </h2>
          <p className="feature-body">{t.body}</p>
          <ul className="feature-points">
            {t.points.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  )
}
