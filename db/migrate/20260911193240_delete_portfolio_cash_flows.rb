class DeletePortfolioCashFlows < ActiveRecord::Migration[7.2]
  def change
    PortfolioCashFlow.destroy_all

  end
end
