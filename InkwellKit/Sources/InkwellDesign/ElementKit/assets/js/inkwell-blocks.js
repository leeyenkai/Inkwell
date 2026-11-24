// Inkwell page elements: extras on top of HTML that already works without this script.

// ==== Elements ====

(function () {
  "use strict";
  var ready = function (fn) { document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", fn) : fn(); };

  // Pictures with a title get a caption.
  function figure(img) {
    var fig = document.createElement("figure");
    img.parentNode.insertBefore(fig, img);
    fig.appendChild(img);
    if (img.title) {
      var cap = document.createElement("figcaption");
      cap.textContent = img.title;
      fig.appendChild(cap);
      img.removeAttribute("title");
    }
    return fig;
  }

  // Gallery: captions, and a large view on click (Escape or a click closes it).
  function gallery(el) {
    var images = Array.prototype.slice.call(el.querySelectorAll("img"));
    images.forEach(function (img) {
      if (img.title) figure(img);
      img.setAttribute("tabindex", "0");
      var open = function () {
        var box = document.createElement("dialog");
        box.className = "ik-lightbox";
        var big = document.createElement("img");
        big.src = img.currentSrc || img.src;
        big.alt = img.alt;
        var close = document.createElement("button");
        close.type = "button";
        close.setAttribute("aria-label", "Close");
        close.textContent = "×";
        box.appendChild(close);
        box.appendChild(big);
        var caption = img.closest("figure") && img.closest("figure").querySelector("figcaption");
        if (caption || img.alt) { var p = document.createElement("p"); p.textContent = caption ? caption.textContent : img.alt; box.appendChild(p); }
        document.body.appendChild(box);
        box.addEventListener("close", function () { box.remove(); });
        box.addEventListener("click", function () { box.close(); });
        box.showModal();
      };
      img.addEventListener("click", open);
      img.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(); } });
    });
  }

  // Slideshow: a snapping strip with arrows, dots, keys and optional autoplay (data-autoplay in seconds).
  function slideshow(el) {
    var images = Array.prototype.slice.call(el.querySelectorAll("img"));
    if (!images.length) return;
    var track = document.createElement("div");
    track.className = "ik-track";
    images.forEach(function (img) { track.appendChild(figure(img)); });
    el.innerHTML = "";
    el.appendChild(track);
    el.classList.add("ik-ready");
    el.setAttribute("tabindex", "0");
    el.setAttribute("aria-roledescription", "slideshow");
    var slides = track.children, index = 0;
    var dots = document.createElement("div");
    dots.className = "ik-dots";
    var go = function (i) {
      index = (i + slides.length) % slides.length;
      track.scrollTo({ left: slides[index].offsetLeft - track.offsetLeft, behavior: "smooth" });
      Array.prototype.forEach.call(dots.children, function (d, n) { d.setAttribute("aria-current", n === index ? "true" : "false"); });
    };
    if (slides.length > 1) {
      [["ik-prev", "‹", "Previous", -1], ["ik-next", "›", "Next", 1]].forEach(function (b) {
        var button = document.createElement("button");
        button.type = "button";
        button.className = b[0];
        button.textContent = b[1];
        button.setAttribute("aria-label", b[2]);
        button.addEventListener("click", function () { go(index + b[3]); });
        el.appendChild(button);
      });
      Array.prototype.forEach.call(slides, function (_, n) {
        var dot = document.createElement("button");
        dot.type = "button";
        dot.setAttribute("aria-label", "Picture " + (n + 1));
        dot.addEventListener("click", function () { go(n); });
        dots.appendChild(dot);
      });
      el.appendChild(dots);
      el.addEventListener("keydown", function (e) { if (e.key === "ArrowLeft") go(index - 1); if (e.key === "ArrowRight") go(index + 1); });
      track.addEventListener("scroll", function () {
        var n = Math.round(track.scrollLeft / Math.max(1, track.clientWidth));
        if (n !== index && n < slides.length) { index = n; go(n); }
      }, { passive: true });
      var seconds = parseFloat(el.getAttribute("data-autoplay"));
      if (seconds > 0 && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        var timer = setInterval(function () { go(index + 1); }, seconds * 1000);
        el.addEventListener("pointerenter", function () { clearInterval(timer); });
        el.addEventListener("focusin", function () { clearInterval(timer); });
      }
      go(0);
    }
  }

  // Tabs: each ### heading starts a tab.
  function tabs(el) {
    var headings = Array.prototype.filter.call(el.children, function (c) { return /^H[2-4]$/.test(c.tagName); });
    if (headings.length < 2) return;
    var level = headings[0].tagName;
    headings = headings.filter(function (h) { return h.tagName === level; });
    var list = document.createElement("div");
    list.setAttribute("role", "tablist");
    var panels = [];
    headings.forEach(function (h, n) {
      var panel = document.createElement("div");
      panel.setAttribute("role", "tabpanel");
      var node = h.nextSibling;
      while (node && !(node.tagName === level)) { var next = node.nextSibling; panel.appendChild(node); node = next; }
      var tab = document.createElement("button");
      tab.type = "button";
      tab.setAttribute("role", "tab");
      tab.textContent = h.textContent;
      tab.id = (el.id || "ik-tabs") + "-tab-" + n + "-" + Math.random().toString(36).slice(2, 7);
      panel.setAttribute("aria-labelledby", tab.id);
      tab.addEventListener("click", function () { select(n); });
      tab.addEventListener("keydown", function (e) {
        if (e.key === "ArrowRight") { select((n + 1) % headings.length); list.children[(n + 1) % headings.length].focus(); }
        if (e.key === "ArrowLeft") { select((n - 1 + headings.length) % headings.length); list.children[(n - 1 + headings.length) % headings.length].focus(); }
      });
      list.appendChild(tab);
      panels.push(panel);
      h.replaceWith(panel);
    });
    el.insertBefore(list, el.firstChild);
    el.classList.add("ik-ready");
    function select(i) {
      Array.prototype.forEach.call(list.children, function (t, n) {
        t.setAttribute("aria-selected", n === i ? "true" : "false");
        t.tabIndex = n === i ? 0 : -1;
        panels[n].hidden = n !== i;
      });
    }
    select(0);
  }

  // Map: places written as geo: links, drawn with Leaflet and OpenStreetMap when online.
  var leaflet;
  function loadLeaflet() {
    if (leaflet) return leaflet;
    leaflet = new Promise(function (resolve, reject) {
      var css = document.createElement("link");
      css.rel = "stylesheet";
      css.href = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css";
      css.integrity = "sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=";
      css.crossOrigin = "";
      document.head.appendChild(css);
      var script = document.createElement("script");
      script.src = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js";
      script.integrity = "sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=";
      script.crossOrigin = "";
      script.onload = function () { resolve(window.L); };
      script.onerror = reject;
      document.head.appendChild(script);
    });
    return leaflet;
  }

  function map(el) {
    var places = Array.prototype.map.call(el.querySelectorAll('a[href^="geo:"]'), function (a) {
      var parts = a.getAttribute("href").slice(4).split(",");
      return { name: a.textContent, lat: parseFloat(parts[0]), lon: parseFloat(parts[1]), link: a };
    }).filter(function (p) { return isFinite(p.lat) && isFinite(p.lon); });
    places.forEach(function (p) { p.link.href = "https://www.openstreetmap.org/?mlat=" + p.lat + "&mlon=" + p.lon + "#map=14/" + p.lat + "/" + p.lon; });
    if (!places.length) return;
    var canvas = document.createElement("div");
    canvas.className = "ik-map-canvas";
    canvas.setAttribute("role", "img");
    canvas.setAttribute("aria-label", "Map of " + places.map(function (p) { return p.name; }).join(", "));
    el.insertBefore(canvas, el.firstChild);
    loadLeaflet().then(function (L) {
      var m = L.map(canvas, { scrollWheelZoom: false });
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
      }).addTo(m);
      var points = places.map(function (p) { L.marker([p.lat, p.lon]).addTo(m).bindPopup(p.name); return [p.lat, p.lon]; });
      var zoom = parseInt(el.getAttribute("data-zoom"), 10) || 12;
      if (points.length === 1) m.setView(points[0], zoom); else m.fitBounds(points, { padding: [30, 30] });
    }).catch(function () { canvas.remove(); });
  }

  // Slides: each section break (<hr>) starts a new slide.
  function slides(el) {
    var groups = [[]];
    Array.prototype.slice.call(el.childNodes).forEach(function (node) {
      if (node.tagName === "HR") groups.push([]); else groups[groups.length - 1].push(node);
    });
    groups = groups.filter(function (g) { return g.some(function (n) { return n.nodeType === 1 || (n.textContent || "").trim(); }); });
    if (groups.length < 1) return;
    el.innerHTML = "";
    var sections = groups.map(function (g) {
      var s = document.createElement("section");
      s.className = "ik-slide";
      g.forEach(function (n) { s.appendChild(n); });
      el.appendChild(s);
      return s;
    });
    var controls = document.createElement("div");
    controls.className = "ik-slide-controls";
    var prev = document.createElement("button"), next = document.createElement("button"), count = document.createElement("span"),
      present = document.createElement("button");
    prev.type = next.type = present.type = "button";
    prev.textContent = "←"; prev.setAttribute("aria-label", "Previous slide");
    next.textContent = "→"; next.setAttribute("aria-label", "Next slide");
    present.textContent = "Present";
    controls.append(prev, count, next, present);
    el.appendChild(controls);
    el.classList.add("ik-ready");
    var index = 0;
    var show = function (i) {
      index = Math.max(0, Math.min(sections.length - 1, i));
      sections.forEach(function (s, n) { s.classList.toggle("ik-current", n === index); });
      count.textContent = (index + 1) + " / " + sections.length;
    };
    prev.addEventListener("click", function () { show(index - 1); });
    next.addEventListener("click", function () { show(index + 1); });
    present.addEventListener("click", function () { if (el.requestFullscreen) el.requestFullscreen(); });
    document.addEventListener("keydown", function (e) {
      if (e.target.closest && e.target.closest("input, textarea")) return;
      if (e.key === "ArrowRight" || e.key === "PageDown" || (e.key === " " && document.fullscreenElement === el)) { e.preventDefault(); show(index + 1); }
      if (e.key === "ArrowLeft" || e.key === "PageUp") { e.preventDefault(); show(index - 1); }
    });
    var start = parseInt((location.hash.match(/^#slide-(\d+)$/) || [])[1], 10);
    show(isFinite(start) ? start - 1 : 0);
  }

  ready(function () {
    var each = function (selector, fn) { Array.prototype.forEach.call(document.querySelectorAll(selector), fn); };
    each(".ik-gallery", gallery);
    each(".ik-slideshow", slideshow);
    each(".ik-tabs", tabs);
    each(".ik-map", map);
    each(".ik-slides", slides);
  });
})();



// ==== Albums ====

// The large view of an album photo is a :target overlay. This adds Escape, the arrow keys and swipes, keeps focus inside
// it while open, and puts focus and the scroll position back on the photo it came from when it closes.
(function () {
  var open = null;
  var scrollY = 0;

  function lightbox() {
    var id = decodeURIComponent(location.hash.slice(1));
    var el = id ? document.getElementById(id) : null;
    return el && el.classList.contains("inkwell-lightbox") ? el : null;
  }

  function sync() {
    var box = lightbox();
    if (box && !open) scrollY = window.scrollY;
    document.documentElement.classList.toggle("inkwell-lightbox-open", !!box);
    if (box) {
      var close = box.querySelector(".inkwell-lightbox-close");
      if (close) close.focus({ preventScroll: true });
    } else if (open) {
      window.scrollTo(0, scrollY);
      var thumb = document.getElementById(open.id + "-thumb");
      if (thumb) {
        thumb.focus({ preventScroll: true });
        thumb.scrollIntoView({ block: "nearest" });
      }
    }
    open = box;
  }

  function follow(box, selector) {
    var link = box.querySelector(selector);
    if (link) link.click();
    return !!link;
  }

  document.addEventListener("keydown", function (event) {
    var box = lightbox();
    if (!box || event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    var keys = { Escape: ".inkwell-lightbox-close", ArrowLeft: ".inkwell-lightbox-prev", ArrowRight: ".inkwell-lightbox-next" };
    if (keys[event.key]) {
      if (follow(box, keys[event.key])) event.preventDefault();
    } else if (event.key === "Tab") {
      var links = Array.prototype.slice.call(box.querySelectorAll("a[href]:not([tabindex='-1'])"));
      if (!links.length) return;
      var i = links.indexOf(document.activeElement);
      event.preventDefault();
      links[(i + (event.shiftKey ? -1 : 1) + links.length) % links.length].focus();
    }
  });

  var startX = null;
  document.addEventListener("touchstart", function (event) {
    startX = lightbox() && event.touches.length === 1 ? event.touches[0].clientX : null;
  }, { passive: true });
  document.addEventListener("touchend", function (event) {
    var box = lightbox();
    if (!box || startX === null || !event.changedTouches.length) return;
    var dx = event.changedTouches[0].clientX - startX;
    if (Math.abs(dx) > 50) follow(box, dx > 0 ? ".inkwell-lightbox-prev" : ".inkwell-lightbox-next");
    startX = null;
  }, { passive: true });

  window.addEventListener("hashchange", sync);
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", sync);
  else sync();
})();

// ==== End ====
