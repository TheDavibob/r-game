// =============================================================================
// celebrate.js -- dancing penguins when a challenge is solved.
//
// The three species from the palmerpenguins data, drawn as inline SVG (so it
// works offline), each with a name tag in the dataset's classic colours.
// Species are drawn from a shuffled "bag" so every species appears before any
// repeats and the same species never comes up twice in a row (also across
// celebrations).
// =============================================================================

const INK = '#1d232b';

const SPECIES = {
  Adelie: { label: 'Adélie', tag: 'darkorange', bill: '#2b2b2b', feet: '#f0a3a0' },
  Chinstrap: { label: 'Chinstrap', tag: 'purple', bill: '#2b2b2b', feet: '#f0a3a0' },
  Gentoo: { label: 'Gentoo', tag: '#008b8b', bill: '#e8551e', feet: '#f28c28' },
};

const MOVES = ['dance-bounce', 'dance-waddle', 'dance-hop', 'dance-shuffle', 'dance-spin'];

// ---- quasi-random species order -------------------------------------------------

let bag = [];
let lastSpecies = null;

function shuffle(a) {
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function nextSpecies() {
  if (!bag.length) {
    bag = shuffle(Object.keys(SPECIES));
    if (bag[0] === lastSpecies) bag.push(bag.shift()); // no back-to-back repeats
  }
  lastSpecies = bag.shift();
  return lastSpecies;
}

const pick = (a) => a[Math.floor(Math.random() * a.length)];

// ---- drawing ----------------------------------------------------------------------

function penguinSvg(species) {
  const s = SPECIES[species];
  // ring: radius of the white eye-ring (0 = none)
  const eyes = (y, ring) => (ring
    ? `<circle cx="41" cy="${y}" r="${ring}" fill="#fff"/><circle cx="59" cy="${y}" r="${ring}" fill="#fff"/>`
    : '') +
    `<circle cx="41.5" cy="${y + 0.5}" r="2.1" fill="${INK}"/><circle cx="58.5" cy="${y + 0.5}" r="2.1" fill="${INK}"/>`;

  // Adélie & Gentoo: black throat, so the belly sits under the head.
  // Chinstrap: white face and throat, so the belly is drawn over the head.
  const bellyLow = '<ellipse cx="50" cy="82" rx="21" ry="29" fill="#fff"/>';
  const bellyHigh = '<ellipse cx="50" cy="74" rx="21" ry="37" fill="#fff"/>';

  let head = `<circle cx="50" cy="32" r="22" fill="${INK}"/>`;
  let face = '';
  if (species === 'Adelie') {
    // All-black head, bold white eye-rings.
    face = eyes(30, 4.4);
  } else if (species === 'Chinstrap') {
    // White face under a black cap, with a thin black strap under the chin.
    face =
      '<ellipse cx="50" cy="38" rx="18" ry="14" fill="#fff"/>' +
      `<path d="M30 37 Q50 68 70 37" fill="none" stroke="${INK}" stroke-width="1.6" stroke-linecap="round"/>` +
      eyes(31, 0);
  } else {
    // Gentoo: white patches above the eyes, joined over the crown.
    face =
      '<path d="M32 32 Q34 20 50 17 Q66 20 68 32 L62 29 Q57 23.5 50 23.5 Q43 23.5 38 29 Z" fill="#fff"/>' +
      eyes(32, 3.3);
  }
  const bill = `<path d="M44.5 37 L55.5 37 L50 46 Z" fill="${s.bill}"/>`;

  return `
<svg viewBox="0 0 100 122" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <ellipse cx="39" cy="114" rx="10" ry="4.5" fill="${s.feet}"/>
  <ellipse cx="61" cy="114" rx="10" ry="4.5" fill="${s.feet}"/>
  <g class="flipper flipper-l"><ellipse cx="22" cy="70" rx="7" ry="22" fill="${INK}" transform="rotate(16 22 70)"/></g>
  <g class="flipper flipper-r"><ellipse cx="78" cy="70" rx="7" ry="22" fill="${INK}" transform="rotate(-16 78 70)"/></g>
  <ellipse cx="50" cy="74" rx="30" ry="40" fill="${INK}"/>
  ${species === 'Chinstrap' ? head + bellyHigh : bellyLow + head}
  ${face}
  ${bill}
</svg>`;
}

function makePenguin(species, index) {
  const s = SPECIES[species];
  const el = document.createElement('div');
  el.className = 'penguin';
  el.style.animationDelay = `${index * 0.08}s`;
  el.innerHTML =
    `<div class="dancer">${penguinSvg(species)}</div>` +
    `<div class="penguin-tag" style="background:${s.tag}">${s.label}</div>`;

  const move = pick(MOVES);
  const dancer = el.querySelector('.dancer');
  if (move === 'dance-spin') {
    dancer.style.animation = `dance-spin ${0.9 + Math.random() * 0.4}s ease-in-out ${Math.random() * 0.3}s infinite`;
  } else {
    dancer.style.animation = `${move} ${0.35 + Math.random() * 0.25}s ease-in-out ${Math.random() * 0.3}s infinite alternate`;
  }
  const flap = `${0.18 + Math.random() * 0.15}s`;
  el.querySelectorAll('.flipper').forEach((f) => { f.style.animationDuration = flap; });
  return el;
}

// ---- public ------------------------------------------------------------------------

const DURATION_MS = 3600;
let current = null;

// count: how many penguins; banner: optional message shown above them;
// species: optional fixed list, e.g. ['Gentoo', 'Adelie'] (for testing).
export function celebrate({ count = 4, banner = '', species = null } = {}) {
  // A fresh bag per celebration, so a troupe of 3+ shows every species. The
  // first penguin still never repeats the previous celebration's last one.
  bag = [];
  const lineup = species || Array.from({ length: count }, nextSpecies);
  current?.remove();
  const stage = document.createElement('div');
  stage.className = 'celebration';
  stage.setAttribute('aria-hidden', 'true');
  if (banner) {
    const b = document.createElement('div');
    b.className = 'celebration-banner';
    b.textContent = banner;
    stage.appendChild(b);
  }
  const line = document.createElement('div');
  line.className = 'penguin-line';
  lineup.forEach((sp, i) => line.appendChild(makePenguin(sp, i)));
  stage.appendChild(line);
  document.body.appendChild(stage);
  current = stage;
  setTimeout(() => { if (current === stage) current = null; stage.remove(); }, DURATION_MS + lineup.length * 80);
}
