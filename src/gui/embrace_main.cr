# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

require "./embrace"

{% if flag?(:cache_validation) %}
CrymbleUI::CacheValidation.enable_all
{% end %}
app = EmbraceApp.new
CrymbleUI.run(app)
