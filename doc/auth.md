# Authentication and Authorization

The idea is to use an additional field "auth" to represent the authentication and/or authorization token.

"auth" field is not present is same as "auth": null

"user.login" has to be sent which returns an auth token to be used in "auth" field.

user_tokens
user_id
auth_token
expires_at
created_at
created_by
updated_at
updated_by
