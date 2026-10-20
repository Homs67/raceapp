// Shared navigation for the portal. Pages carry only their own content;
// this renders the sidebar, the current page's section links, prev/next,
// and the theme toggle — so adding a page means one line here.
(function () {
  const PAGES = [
    ["Start here", [
      ["index.html", "Overview"],
      ["status.html", "Status & known issues"],
    ]],
    ["How it works", [
      ["hardware.html", "Data sources"],
      ["pipeline.html", "Telemetry pipeline"],
      ["motion.html", "Motion, laps & G-force"],
      ["dashboard.html", "Dashboard system"],
    ]],
    ["Code", [
      ["packages.html", "Swift packages"],
      ["app.html", "App layer"],
      ["workflow.html", "Dev workflow"],
    ]],
  ];
  const flat = PAGES.flatMap(([, pages]) => pages);
  const here = location.pathname.split("/").pop() || "index.html";

  // Theme: follows the system unless the reader picks one.
  const root = document.documentElement;
  try {
    const saved = localStorage.getItem("arch-theme");
    if (saved) root.setAttribute("data-theme", saved);
  } catch (e) {}

  document.addEventListener("DOMContentLoaded", () => {
    const nav = document.getElementById("nav");
    if (nav) {
      nav.innerHTML = "";
      const sections = [...document.querySelectorAll("main h2[id]")];
      for (const [group, pages] of PAGES) {
        const g = document.createElement("div");
        g.className = "group";
        g.textContent = group;
        nav.appendChild(g);
        for (const [href, title] of pages) {
          const a = document.createElement("a");
          a.href = href;
          a.className = "page" + (href === here ? " active" : "");
          a.textContent = title;
          nav.appendChild(a);
          if (href === here && sections.length) {
            const box = document.createElement("div");
            box.className = "sections";
            for (const h of sections) {
              const s = document.createElement("a");
              s.href = "#" + h.id;
              s.textContent = h.dataset.short || h.textContent;
              box.appendChild(s);
            }
            nav.appendChild(box);
          }
        }
      }
    }

    const main = document.querySelector("main");
    const i = flat.findIndex(([href]) => href === here);
    if (main && i >= 0) {
      const foot = document.createElement("footer");
      foot.className = "page-foot";
      const prev = flat[i - 1], next = flat[i + 1];
      foot.innerHTML =
        "<span>" + (prev ? '← <a href="' + prev[0] + '">' + prev[1] + "</a>" : "") + "</span>" +
        "<span>" + (next ? '<a href="' + next[0] + '">' + next[1] + "</a> →" : "") + "</span>";
      main.appendChild(foot);
    }

    const toggle = document.getElementById("theme-toggle");
    if (toggle) {
      const label = () => {
        const t = root.getAttribute("data-theme");
        toggle.textContent = t === "dark" ? "Dark" : t === "light" ? "Light" : "Auto";
      };
      label();
      toggle.addEventListener("click", () => {
        const order = [null, "light", "dark"];
        const cur = root.getAttribute("data-theme");
        const nextT = order[(order.indexOf(cur) + 1) % order.length];
        if (nextT) root.setAttribute("data-theme", nextT); else root.removeAttribute("data-theme");
        try { nextT ? localStorage.setItem("arch-theme", nextT) : localStorage.removeItem("arch-theme"); } catch (e) {}
        label();
      });
    }
  });
})();
