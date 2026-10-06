package orm.example.tableless

import orm

export main

class SignupForm:
  use orm.tableless:
    schema:
      attribute(:email, type: :text)
      attribute(:password, type: :text)

    validate:
      expect(:email, email.present?, message: "must be present")
      expect(:password, password.length >= 12, code: :length, message: "length must be at least 12")

def main():
  form = SignupForm(email: "ada@example.test", password: "correct horse")
  form.save.or_raise
  form.persisted?
