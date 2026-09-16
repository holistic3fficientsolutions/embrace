# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "./embrace"
require "./probe"

{% if flag?(:cache_validation) %}
CrymbleUI::CacheValidation.enable_all
{% end %}
app = EmbraceApp.new
{% if flag?(:probe) %}
  # Diagnostic build only (-Dprobe). Starts a per-frame log beside the executable; see probe.cr for
  # what it watches and, importantly, what it cannot see.
  EmbraceProbe.start(app)
{% end %}
CrymbleUI.run(app)
