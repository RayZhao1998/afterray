import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

const TICKS = ['09:00', '10:00', '11:00', '12:00', '13:00', '14:00', '15:00']

export default function Rewind() {
  const t = useCopy().rewind
  return (
    <section className="section feature" id="features">
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
        <div className="mock timeline-mock">
          <div className="mock-bar">
            <span className="mono dim">{t.mock.bar}</span>
            <span className="mono accent">13:42:07</span>
          </div>
          <div className="timeline-track">
            <div className="timeline-fill" />
            <div className="timeline-playhead">
              <span className="playhead-dot" />
            </div>
            {TICKS.map((tick, i) => (
              <span
                key={tick}
                className={`timeline-tick mono ${i === 4 ? 'tick-active' : ''}`}
                style={{ left: `${6 + i * 15}%` }}
              >
                {tick}
              </span>
            ))}
          </div>
          <div className="timeline-cards">
            {t.mock.cards.map((c, i) => (
              <div key={c.time} className={`tl-card ${i === 0 ? 'tl-active' : ''}`}>
                <span className="mono dim">{c.time}</span>
                <p>{c.text}</p>
              </div>
            ))}
          </div>
        </div>
      </Reveal>
    </section>
  )
}
