const slides = Array.from(document.querySelectorAll(".slide"));
const railModules = Array.from(document.querySelectorAll(".rail-module"));
const railTitles = Array.from(document.querySelectorAll(".rail-title"));
const counter = document.getElementById("counter");
const progress = document.getElementById("progress");
const prevBtn = document.getElementById("prev");
const nextBtn = document.getElementById("next");
const deckApp = document.querySelector(".deck-app");
const modeBadge = document.getElementById("mode-badge");

let current = 0;
let isAnimating = false;

const modeMap = {
  0: "normal",
  1: "command",
  2: "insert",
  3: "visual",
  4: "replace",
  5: "terminal",
  6: "normal",
  7: "command",
  8: "insert",
  9: "visual"
};

function buildDots() {
  const moduleMap = {};
  slides.forEach((slide, idx) => {
    const mod = slide.dataset.module;
    if (!moduleMap[mod]) moduleMap[mod] = [];
    moduleMap[mod].push(idx);
  });

  Object.entries(moduleMap).forEach(([mod, indices]) => {
    const container = document.getElementById(`dots-${mod}`);
    if (!container) return;
    indices.forEach((slideIdx) => {
      const pip = document.createElement("button");
      pip.className = "rail-pip";
      pip.dataset.slide = slideIdx;
      pip.setAttribute("aria-label", `Slide ${slideIdx + 1}`);
      pip.addEventListener("click", () => render(slideIdx));
      container.appendChild(pip);
    });
  });
}

function pad(value) {
  return String(value).padStart(2, "0");
}

function cleanupTransitionClasses(slide) {
  slide.classList.remove(
    "is-entering",
    "is-leaving",
    "from-next",
    "from-prev",
    "to-next",
    "to-prev"
  );
}

function updateChrome() {
  const pips = Array.from(document.querySelectorAll(".rail-pip"));
  pips.forEach((pip) => {
    pip.classList.toggle("is-active", Number(pip.dataset.slide) === current);
  });

  const currentModule = slides[current]?.dataset.module;
  railModules.forEach((mod) => {
    mod.classList.toggle("is-active-module", mod.dataset.module === currentModule);
  });

  const ratio = ((current + 1) / slides.length) * 100;
  progress.style.width = `${ratio}%`;
  counter.textContent = `${pad(current + 1)} / ${pad(slides.length)}`;

  prevBtn.disabled = current === 0;
  nextBtn.disabled = current === slides.length - 1;

  const tone = slides[current]?.dataset.tone;
  const moduleIdx = Number(currentModule);
  const mode = modeMap[moduleIdx] || "normal";

  deckApp.className = deckApp.className
    .replace(/tone-\w+/g, "")
    .replace(/mode-\w+/g, "")
    .replace(/\s+/g, " ")
    .trim();

  if (tone) deckApp.classList.add(`tone-${tone}`);
  deckApp.classList.add(`mode-${mode}`);

  if (modeBadge) {
    modeBadge.textContent = mode.toUpperCase();
  }
}

function render(index, options = {}) {
  const { animate = true } = options;
  const next = Math.max(0, Math.min(index, slides.length - 1));

  if (next === current && animate) {
    updateChrome();
    return;
  }

  if (isAnimating) return;

  const previous = current;
  current = next;
  try { localStorage.setItem("deck-slide", current); } catch (_) {}
  const direction = next > previous ? "next" : "prev";
  const currentSlide = slides[current];
  const previousSlide = slides[previous];

  if (!animate) {
    slides.forEach((slide, idx) => {
      cleanupTransitionClasses(slide);
      slide.classList.toggle("is-active", idx === current);
    });
    updateChrome();
    return;
  }

  isAnimating = true;
  cleanupTransitionClasses(previousSlide);
  cleanupTransitionClasses(currentSlide);

  previousSlide.classList.remove("is-active");
  previousSlide.classList.add("is-leaving", direction === "next" ? "to-next" : "to-prev");

  currentSlide.classList.add("is-active", "is-entering", direction === "next" ? "from-next" : "from-prev");

  const finish = () => {
    cleanupTransitionClasses(previousSlide);
    cleanupTransitionClasses(currentSlide);
    isAnimating = false;
  };

  window.setTimeout(finish, 440);
  updateChrome();
}

railTitles.forEach((title) => {
  title.addEventListener("click", () => {
    const firstSlide = Number(title.dataset.first);
    render(firstSlide);
  });
});

prevBtn.addEventListener("click", () => render(current - 1));
nextBtn.addEventListener("click", () => render(current + 1));

window.addEventListener("keydown", (event) => {
  if (event.key === "ArrowRight" || event.key === "PageDown" || event.key === " ") {
    event.preventDefault();
    render(current + 1);
  }
  if (event.key === "ArrowLeft" || event.key === "PageUp") {
    event.preventDefault();
    render(current - 1);
  }
  if (event.key === "Home") render(0);
  if (event.key === "End") render(slides.length - 1);
  if (event.key.toLowerCase() === "f") {
    document.body.classList.toggle("focus-mode");
  }
});

let touchStartX = 0;
window.addEventListener("touchstart", (event) => {
  touchStartX = event.changedTouches[0].screenX;
});
window.addEventListener("touchend", (event) => {
  const touchEndX = event.changedTouches[0].screenX;
  const delta = touchEndX - touchStartX;
  if (Math.abs(delta) < 40) return;
  if (delta < 0) render(current + 1);
  if (delta > 0) render(current - 1);
});

buildDots();
const saved = Number(localStorage.getItem("deck-slide")) || 0;
render(Math.min(saved, slides.length - 1), { animate: false });
