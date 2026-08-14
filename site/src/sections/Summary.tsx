import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function Summary() {
  const t = useCopy().summary
  return (
    <section className="section feature">
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
      <Reveal className="feature-mock" delay={150}>
        <div className="mock summary-mock">
          <div className="mock-bar">
            <span className="mono dim">{t.mock.bar}</span>
            <span className="badge-local mono">LOCAL LLM</span>
          </div>
          {t.mock.hours.map((h) => (
            <div key={h.span} className={`hour-card ${h.active ? 'hour-active' : ''}`}>
              <div className="hour-head">
                <span className="mono accent">{h.span}</span>
                <strong>{h.title}</strong>
              </div>
              <ul>
                {h.points.map((p) => (
                  <li key={p}>{p}</li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </Reveal>
    </section>
  )
}
