locals {
  lambda_memory_size = 256
  lambda_timeout     = 60

  lifecycle_policies = {
    "production/daily" = {
      ia_transition_days = 7
      expiration_days    = 60
    }
    "production/weekly" = {
      ia_transition_days = 7
      expiration_days    = 84
    }
    "production/monthly" = {
      ia_transition_days      = 7
      glacier_transition_days = 37
      expiration_days         = 396
    }
    "production/quarterly" = {
      ia_transition_days      = 7
      glacier_transition_days = 90
      expiration_days         = 1095
    }
    "production/semi-annual" = {
      ia_transition_days      = 7
      glacier_transition_days = 180
      expiration_days         = 2555
    }
    "production/annual" = {
      ia_transition_days      = 7
      glacier_transition_days = 365
      expiration_days         = 2555
    }
    "test/daily"       = { expiration_days = 7 }
    "test/weekly"      = { expiration_days = 7 }
    "test/monthly"     = { expiration_days = 7 }
    "test/quarterly"   = { expiration_days = 7 }
    "test/semi-annual" = { expiration_days = 7 }
    "test/annual"      = { expiration_days = 7 }
  }
}
