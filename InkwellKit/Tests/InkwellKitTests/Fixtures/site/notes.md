---
layout: default
title: Notes
---

# Notes

<ul class="post-list">
{% for post in site.notes reversed %}
  <li class="post-list-item">
    <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%b %d, %Y" }}</time>
    <h3><a href="{{ post.url | relative_url }}">{{ post.title }}</a></h3>
  </li>
{% endfor %}
</ul>
