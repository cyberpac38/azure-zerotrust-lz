# The budget is a smoke detector, not a cap. Azure budgets are
# notification-only: no throttle, no halt, no cutoff. down.sh and the nightly
# teardown workflow are the only things that actually control spend.
#
# $50 rather than $20 on purpose. The firewall alone is roughly $40 a month at
# two four-hour sessions a weekend, so a budget set below normal working spend
# would fire every month during correct operation - and an alert you learn to
# ignore is worse than no alert at all. The useful threshold is the first one:
# 25% is $12.50, roughly ten firewall-hours, so a 25% alert arriving on the
# 3rd of a month means something did not get torn down.
#
# This resource ADOPTS the budget created by hand on 1 November, via
# terraform import, rather than creating a second one. start_date forces
# replacement when it changes, so both dates below are the portal's exact
# values - a mismatch there would destroy and rebuild the only live cost alarm
# instead of adopting it.
#
# Notifications go to the Owner role rather than to an email address, because
# this repository is public and an address written here is an address
# published.

data "azurerm_subscription" "current" {}

resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "budget-ztlz-monthly"
  subscription_id = data.azurerm_subscription.current.id

  amount     = 50
  time_grain = "Monthly"

  time_period {
    start_date = "2026-11-01T00:00:00Z"
    end_date   = "2028-10-31T00:00:00Z"
  }

  # $12.50 - the real early warning.
  notification {
    enabled        = true
    threshold      = 25.0
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_roles  = ["Owner"]
  }

  # $25
  notification {
    enabled        = true
    threshold      = 50.0
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_roles  = ["Owner"]
  }

  # $40
  notification {
    enabled        = true
    threshold      = 80.0
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_roles  = ["Owner"]
  }

  # $50
  notification {
    enabled        = true
    threshold      = 100.0
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_roles  = ["Owner"]
  }

  # Forecast rather than actual: catches a firewall left running roughly a day
  # earlier than the actual-spend alerts do.
  notification {
    enabled        = true
    threshold      = 100.0
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_roles  = ["Owner"]
  }
}
