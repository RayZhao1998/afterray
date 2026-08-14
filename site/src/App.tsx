import { LangProvider, useLang, useCopy } from './i18n'
import Hero from './sections/Hero'
import Privacy from './sections/Privacy'
import Rewind from './sections/Rewind'
import Search from './sections/Search'
import Summary from './sections/Summary'
import Skills from './sections/Skills'
import Specs from './sections/Specs'

function Nav() {
  const { lang, setLang } = useLang()
  const t = useCopy().nav
  return (
    <nav className="nav">
      <a className="nav-logo" href="#top">
        <img src="/logo.png" alt="AfterRay logo" className="logo-img" />
        <span className="mono">AFTERRAY</span>
      </a>
      <div className="nav-links mono">
        <a href="#features">{t.features}</a>
        <a href="#skills">{t.skills}</a>
        <a href="#privacy">{t.privacy}</a>
      </div>
      <div className="nav-actions">
        <button
          className="lang-toggle mono"
          onClick={() => setLang(lang === 'en' ? 'zh' : 'en')}
          aria-label="Switch language"
        >
          {lang === 'en' ? '中文' : 'EN'}
        </button>
        <a className="btn btn-small" href="#download">
          {t.download}
        </a>
      </div>
    </nav>
  )
}

export default function App() {
  return (
    <LangProvider>
      <div className="app" id="top">
        <Nav />
        <Hero />
        <main>
          <Privacy />
          <Rewind />
          <Search />
          <Summary />
          <Skills />
          <Specs />
        </main>
        <div className="grain" aria-hidden="true" />
      </div>
    </LangProvider>
  )
}
