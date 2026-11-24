---
layout: default
title: Sidenotes
---

# Sidenotes

{% assign _sidenotes_sorted = site.sidenotes | sort: 'date' %}
{% for post in _sidenotes_sorted reversed %}

<article class="sidenote-item">
  <div class="sidenote-meta">
    <time class="sidenote-date">{{ post.date | date: "%b %-d, %Y" }}</time>
  </div>

  <div class="sidenote-content">
    {{ post.content }}
  </div>

</article>

{% endfor %}
