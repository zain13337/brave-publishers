module Logout
  def logout_everybody!
    current_publisher.invalidate_all_sessions!
    sign_out(current_publisher)
  end

  def logout_everybody_else!
    current_publisher.invalidate_all_sessions!
    # save the current publisher here, after sign_out this variable will be cleared
    publisher = current_publisher
    sign_out(current_publisher)
    sign_in(:publisher, publisher)
  end
end
