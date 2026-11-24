// Inkwell page elements: extras on top of HTML that already works without this script.

// ==== Elements ====



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
