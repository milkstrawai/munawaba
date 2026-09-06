(function () {
  "use strict";
  var app = document.querySelector(".mn-app");
  if (!app) return;
  var errors = app.querySelector("[data-mn-errors]");
  if (errors) errors.focus();
  var menu = app.querySelector("[data-mn-menu]");
  if (menu && window.matchMedia("(max-width: 720px)").matches) menu.open = false;
  if (menu) menu.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && window.matchMedia("(max-width: 720px)").matches) {
      menu.open = false;
      menu.querySelector("summary").focus();
    }
  });
  var order = app.querySelector("[data-mn-order]");
  if (!order) return;
  var dragged = null;
  order.addEventListener("dragstart", function (event) {
    dragged = event.target.closest("[data-mn-person-id]");
    if (!dragged) return;
    dragged.setAttribute("data-mn-dragging", "true");
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", dragged.getAttribute("data-mn-person-id"));
  });
  order.addEventListener("dragover", function (event) {
    if (!dragged) return;
    event.preventDefault();
    var target = event.target.closest("[data-mn-person-id]");
    if (target && target !== dragged) {
      var bounds = target.getBoundingClientRect();
      order.insertBefore(dragged, event.clientY < bounds.top + bounds.height / 2 ? target : target.nextSibling);
    }
  });
  order.addEventListener("drop", function (event) {
    if (!dragged) return;
    event.preventDefault();
    var rows = order.querySelectorAll("[data-mn-person-id]");
    rows.forEach(function (row, index) {
      row.querySelector(".mn-position").textContent = index + 1;
      var badge = row.querySelector(".mn-badge-next");
      if (badge) badge.remove();
      if (index === 0) {
        badge = document.createElement("span");
        badge.className = "mn-badge mn-badge-next";
        badge.textContent = "Next";
        row.querySelector("strong").after(badge);
      }
      row.querySelector('[value^="up:"]').disabled = index === 0;
      row.querySelector('[value^="down:"]').disabled = index === rows.length - 1;
      row.querySelector('[value^="next:"]').disabled = index === 0;
    });
    var confirmation = app.querySelector("#mn-confirmation-form");
    if (confirmation) confirmation.remove();
    app.querySelector("[data-mn-order-announcement]").textContent = "Order changed. Update the preview to review and save this order.";
  });
  order.addEventListener("dragend", function () {
    if (dragged) dragged.removeAttribute("data-mn-dragging");
    dragged = null;
  });
}());
