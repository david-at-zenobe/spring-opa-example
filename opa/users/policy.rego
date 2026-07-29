package com.zenobe.authz.users

import rego.v1

initialised := data.initialised

revision := data.users.revision

user := data.users.entries[input.user]

result := {"org": user.org}

response := {
	"initialised": initialised,
	"revision": revision,
	"result": result,
}
