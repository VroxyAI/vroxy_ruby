# frozen_string_literal: true

module Ctovibe
  # Resolves the {email, name, external_id, role, meta} hash the
  # snippet forwards to `ctovibe.identify(...)`.
  #
  # Order of precedence:
  #   1. `Ctovibe.configuration.identify` — if set, its return
  #      value wins (or `nil` to explicitly stay anonymous).
  #   2. Auto-detect from `controller.current_user` — covers the
  #      95% Devise / Clearance / has_secure_password case.
  #
  # Auto-detect only pulls fields the model actually exposes; a
  # user without a `role` column just gets `role: nil`, and the
  # snippet omits null-valued keys before serializing.
  module Identity
    module_function

    # Public entry point.  Returns a hash (possibly empty) or nil.
    def resolve(controller)
      block = Ctovibe.configuration.identify
      return normalize(block.call(controller)) if block

      user = detect_current_user(controller)
      return nil unless user

      auto_infer(user)
    end

    # Strip nil/blank values so the emitted JS payload doesn't
    # ship `email: null` for anonymous-ish rows.  `meta` is kept
    # even if empty-hash-y? no — drop it too; ctovibe.identify
    # tolerates missing keys.
    def normalize(hash)
      return nil if hash.nil?
      return nil unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(k, v), out|
        key = k.to_sym
        next if v.nil?
        next if v.respond_to?(:empty?) && v.empty?
        out[key] = v
      end
    end

    def detect_current_user(controller)
      return nil unless controller.respond_to?(:current_user, true)
      controller.send(:current_user)
    rescue StandardError
      # A broken `current_user` (DB down, cache miss on a lazy
      # loader, custom exceptions) shouldn't take out the entire
      # page render.  Anonymous is a safe fallback.
      nil
    end

    # Best-effort field extraction.  Every accessor is optional so
    # a bare `User` with just `id` + `email` still yields a useful
    # identify payload.
    def auto_infer(user)
      {
        external_id: read(user, :id)&.to_s,
        email:       read(user, :email),
        name:        infer_name(user),
        role:        infer_role(user)
      }.compact
    end

    # Try common name accessors in the order most apps define
    # them.  `full_name` first because it's the explicit "display"
    # convention; `name` next because Devise scaffolds it; the
    # first_name/last_name join is a last resort.
    def infer_name(user)
      %i[full_name name display_name].each do |m|
        v = read(user, m)
        return v if v.is_a?(String) && !v.empty?
      end

      first = read(user, :first_name)
      last  = read(user, :last_name)
      joined = [first, last].compact.reject(&:empty?).join(" ")
      joined.empty? ? nil : joined
    end

    # `role` covers single-role columns; `roles` covers has_many
    # :roles associations (Rolify et al.) — we serialize the first
    # role's name/to_s so the widget can gate on it uniformly.
    def infer_role(user)
      v = read(user, :role)
      return v.to_s if v && !v.to_s.empty?

      roles = read(user, :roles)
      return nil unless roles
      first = roles.respond_to?(:first) ? roles.first : nil
      return nil unless first
      (first.respond_to?(:name) ? first.name : first).to_s
    end

    def read(user, method)
      user.public_send(method) if user.respond_to?(method)
    rescue StandardError
      nil
    end
  end
end
