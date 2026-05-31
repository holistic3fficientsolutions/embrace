# SPDX-FileCopyrightText: 2026 Wolfgang Mayerle <wolfgang.mayerle@h3o.de>
# SPDX-License-Identifier: AGPL-3.0-only

class EmbraceException < Exception
end

class ConditionsNotMet < Exception
    def initialize(message : String)
        super(message + "; ignoring command")
    end
end
