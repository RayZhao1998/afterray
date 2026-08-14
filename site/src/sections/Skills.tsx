import Reveal from '../components/Reveal'
import { Rich, useCopy } from '../i18n'

export default function Skills() {
  const t = useCopy().skills
  return (
    <section className="section skills" id="skills">
      <Reveal className="skills-head">
        <p className="eyebrow mono">{t.eyebrow}</p>
        <h2 className="skills-title">
          <Rich parts={t.titleA} />
          <br />
          <Rich parts={t.titleB} />
        </h2>
        <p className="skills-sub">{t.sub}</p>
      </Reveal>

      <div className="skills-grid">
        <Reveal className="skills-col">
          <p className="mono dim col-label">{t.extractedLabel}</p>
          {t.extracted.map((s) => (
            <div key={s.name} className="skill-card">
              <div className="skill-top">
                <strong>{s.name}</strong>
                <span className="mono accent">{s.level}</span>
              </div>
              <div className="skill-meta mono dim">
                <span>{s.hours}</span>
                <span>{s.evidence}</span>
              </div>
            </div>
          ))}
        </Reveal>
        <Reveal className="skills-col" delay={150}>
          <p className="mono dim col-label">{t.suggestedLabel}</p>
          {t.suggested.map((s) => (
            <div key={s.name} className="skill-card skill-suggest">
              <div className="skill-top">
                <strong>{s.name}</strong>
                <span className="suggest-tag mono">{s.tag}</span>
              </div>
              <p className="skill-why">{s.why}</p>
            </div>
          ))}
          <p className="mono dim skills-note">{t.note}</p>
        </Reveal>
      </div>
    </section>
  )
}
