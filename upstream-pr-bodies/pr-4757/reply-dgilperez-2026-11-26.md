Thanks, all three points are right. I reproduced each one with a test against this branch and against main, and fixed them in e97f7c302.

**Split checks.** I removed the child entries from `Entry#accounts_changed_by_transfer_removal` and dropped the unsplit and resplit permission checks from both split controllers. With #4966 in main, these operations are refused with its own message (and a 422 in the API), and that answer now stays as it is.

**Rule action.** The rule no longer skips split parts. Split parents still stay out through the excluded filter. I had copied the filter from `Transfer::Matcher#match_with!`, which still refuses split parts on main. I followed #4955 here, because it needs the rule to link split parts.

**Projection.** `Account#scheduled_entry_flows` now counts the legs and fees of confirmed transfers for these two account types. The calculator and the projection use the same lookup, `Account#confirmed_transfer_transaction_ids`. Your example now projects checking at 1,500 and the liability at 1,500.

**One more path.** The API transaction delete and the assistant's delete tool did not check the other side the way the web delete does. A member could delete a payment leg and move another member's liability balance. Both now need write access to the accounts the deletion changes, with a test for each.

Smaller changes in the same commit: bulk delete now says why it kept such an entry, a split transfer fee keeps counting through its parts, the reconciliation shows only the cash flow on cash accounts again, and the accounts changed by a deletion resync in full, because a fee can be dated before the deleted leg.

I also updated the PR description.
